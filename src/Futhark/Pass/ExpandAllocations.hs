{-# LANGUAGE TypeFamilies #-}

-- | Expand allocations inside of maps when possible.
module Futhark.Pass.ExpandAllocations (expandAllocations) where

import Control.Monad
import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Writer
import Data.Either (rights)
import Data.List (find, foldl')
import Data.Map.Strict qualified as M
import Data.Maybe
import Futhark.Analysis.Alias as Alias
import Futhark.Analysis.SymbolTable qualified as ST
import Futhark.Error
import Futhark.IR
import Futhark.IR.GPU.Simplify qualified as GPU
import Futhark.IR.GPUMem
import Futhark.IR.Mem.IxFun qualified as IxFun
import Futhark.MonadFreshNames
import Futhark.Optimise.Simplify.Rep (addScopeWisdom)
import Futhark.Pass
import Futhark.Pass.ExplicitAllocations.GPU (explicitAllocationsInStms)
import Futhark.Pass.ExtractKernels.BlockedKernel (nonSegRed)
import Futhark.Pass.ExtractKernels.ToGPU (segThread)
import Futhark.Tools
import Futhark.Transform.CopyPropagate (copyPropagateInFun)
import Futhark.Transform.Rename (renameStm)
import Futhark.Transform.Substitute
import Futhark.Util (mapAccumLM)
import Prelude hiding (quot)

-- | The memory expansion pass definition.
expandAllocations :: Pass GPUMem GPUMem
expandAllocations =
  Pass "expand allocations" "Expand allocations" $
    \prog -> do
      consts' <-
        modifyNameSource $
          limitationOnLeft
            . runStateT (runReaderT (transformStms (progConsts prog)) mempty)
      funs' <- mapM (transformFunDef $ scopeOf consts') (progFuns prog)
      pure $ prog {progConsts = consts', progFuns = funs'}

-- Cannot use intraproceduralTransformation because it might create
-- duplicate size keys (which are not fixed by renamer, and size
-- keys must currently be globally unique).

type ExpandM = ReaderT (Scope GPUMem) (StateT VNameSource (Either String))

limitationOnLeft :: Either String a -> a
limitationOnLeft = either compilerLimitationS id

transformFunDef ::
  Scope GPUMem ->
  FunDef GPUMem ->
  PassM (FunDef GPUMem)
transformFunDef scope fundec = do
  body' <- modifyNameSource $ limitationOnLeft . runStateT (runReaderT m mempty)
  copyPropagateInFun
    simpleGPUMem
    (ST.fromScope (addScopeWisdom scope))
    fundec {funDefBody = body'}
  where
    m =
      localScope scope $
        inScopeOf fundec $
          transformBody $
            funDefBody fundec

transformBody :: Body GPUMem -> ExpandM (Body GPUMem)
transformBody (Body () stms res) = Body () <$> transformStms stms <*> pure res

transformLambda :: Lambda GPUMem -> ExpandM (Lambda GPUMem)
transformLambda (Lambda params ret body) =
  Lambda params ret
    <$> localScope (scopeOfLParams params) (transformBody body)

transformStms :: Stms GPUMem -> ExpandM (Stms GPUMem)
transformStms stms =
  inScopeOf stms $ mconcat <$> mapM transformStm (stmsToList stms)

transformStm :: Stm GPUMem -> ExpandM (Stms GPUMem)
-- It is possible that we are unable to expand allocations in some
-- code versions.  If so, we can remove the offending branch.  Only if
-- all versions fail do we propagate the error.
-- FIXME: this can remove safety checks if the default branch fails!
transformStm (Let pat aux (Match cond cases defbody (MatchDec ts MatchEquiv))) = do
  let onCase (Case vs body) =
        (Right . Case vs <$> transformBody body) `catchError` (pure . Left)
  cases' <- rights <$> mapM onCase cases
  defbody' <- (Right <$> transformBody defbody) `catchError` (pure . Left)
  case (cases', defbody') of
    ([], Left e) ->
      throwError e
    (_ : _, Left _) ->
      pure $ oneStm $ Let pat aux $ Match cond (init cases') (caseBody $ last cases') (MatchDec ts MatchEquiv)
    (_, Right defbody'') ->
      pure $ oneStm $ Let pat aux $ Match cond cases' defbody'' (MatchDec ts MatchEquiv)
transformStm (Let pat aux e) = do
  (stms, e') <- transformExp =<< mapExpM transform e
  pure $ stms <> oneStm (Let pat aux e')
  where
    transform =
      identityMapper
        { mapOnBody = \scope -> localScope scope . transformBody
        }

transformExp :: Exp GPUMem -> ExpandM (Stms GPUMem, Exp GPUMem)
transformExp (Op (Inner (SegOp (SegMap lvl space ts kbody)))) = do
  (alloc_stms, (lvl', _, kbody')) <- transformScanRed lvl space [] kbody
  pure
    ( alloc_stms,
      Op $ Inner $ SegOp $ SegMap lvl' space ts kbody'
    )
transformExp (Op (Inner (SegOp (SegRed lvl space reds ts kbody)))) = do
  (alloc_stms, (lvl', lams, kbody')) <-
    transformScanRed lvl space (map segBinOpLambda reds) kbody
  let reds' = zipWith (\red lam -> red {segBinOpLambda = lam}) reds lams
  pure
    ( alloc_stms,
      Op $ Inner $ SegOp $ SegRed lvl' space reds' ts kbody'
    )
transformExp (Op (Inner (SegOp (SegScan lvl space scans ts kbody)))) = do
  (alloc_stms, (lvl', lams, kbody')) <-
    transformScanRed lvl space (map segBinOpLambda scans) kbody
  let scans' = zipWith (\red lam -> red {segBinOpLambda = lam}) scans lams
  pure
    ( alloc_stms,
      Op $ Inner $ SegOp $ SegScan lvl' space scans' ts kbody'
    )
transformExp (Op (Inner (SegOp (SegHist lvl space ops ts kbody)))) = do
  (alloc_stms, (lvl', lams', kbody')) <- transformScanRed lvl space lams kbody
  let ops' = zipWith onOp ops lams'
  pure
    ( alloc_stms,
      Op $ Inner $ SegOp $ SegHist lvl' space ops' ts kbody'
    )
  where
    lams = map histOp ops
    onOp op lam = op {histOp = lam}
transformExp (WithAcc inputs lam) = do
  lam' <- transformLambda lam
  (input_alloc_stms, inputs') <- mapAndUnzipM onInput inputs
  pure
    ( mconcat input_alloc_stms,
      WithAcc inputs' lam'
    )
  where
    onInput (shape, arrs, Nothing) =
      pure (mempty, (shape, arrs, Nothing))
    onInput (shape, arrs, Just (op_lam, nes)) = do
      bound_outside <- asks $ namesFromList . M.keys
      let -- XXX: fake a SegLevel, which we don't have here.  We will not
          -- use it for anything, as we will not allow irregular
          -- allocations inside the update function.
          lvl = SegThread SegNoVirt Nothing
          (op_lam', lam_allocs) =
            extractLambdaAllocations (lvl, [0]) bound_outside mempty op_lam
          variantAlloc (_, Var v, _) = v `notNameIn` bound_outside
          variantAlloc _ = False
          (variant_allocs, invariant_allocs) = M.partition variantAlloc lam_allocs

      case M.elems variant_allocs of
        (_, v, _) : _ ->
          throwError $
            "Cannot handle un-sliceable allocation size: "
              ++ prettyString v
              ++ "\nLikely cause: irregular nested operations inside accumulator update operator."
        [] ->
          pure ()

      let num_is = shapeRank shape
          is = map paramName $ take num_is $ lambdaParams op_lam
      (alloc_stms, alloc_offsets) <-
        genericExpandedInvariantAllocations (const (shape, map le64 is)) invariant_allocs

      scope <- askScope
      let scope' = scopeOf op_lam <> scope
      either throwError pure $
        runOffsetM scope' alloc_offsets $ do
          op_lam'' <- offsetMemoryInLambda op_lam'
          pure (alloc_stms, (shape, arrs, Just (op_lam'', nes)))
transformExp e =
  pure (mempty, e)

ensureGridKnown :: SegLevel -> ExpandM (Stms GPUMem, SegLevel, KernelGrid)
ensureGridKnown lvl =
  case lvl of
    SegThread _ (Just grid) -> pure (mempty, lvl, grid)
    SegBlock _ (Just grid) -> pure (mempty, lvl, grid)
    SegThread virt Nothing -> mkGrid (SegThread virt)
    SegBlock virt Nothing -> mkGrid (SegBlock virt)
    SegThreadInBlock {} -> error "ensureGridKnown: SegThreadInBlock"
  where
    mkGrid f = do
      (grid, stms) <-
        runBuilder $
          KernelGrid
            <$> (Count <$> getSize "num_tblocks" SizeGrid)
            <*> (Count <$> getSize "tblock_size" SizeThreadBlock)
      pure (stms, f $ Just grid, grid)

    getSize desc size_class = do
      size_key <- nameFromString . prettyString <$> newVName desc
      letSubExp desc $ Op $ Inner $ SizeOp $ GetSize size_key size_class

transformScanRed ::
  SegLevel ->
  SegSpace ->
  [Lambda GPUMem] ->
  KernelBody GPUMem ->
  ExpandM (Stms GPUMem, (SegLevel, [Lambda GPUMem], KernelBody GPUMem))
transformScanRed lvl space ops kbody = do
  bound_outside <- asks $ namesFromList . M.keys
  let user = (lvl, [le64 $ segFlat space])
      (kbody', kbody_allocs) =
        extractKernelBodyAllocations user bound_outside bound_in_kernel kbody
      (ops', ops_allocs) =
        unzip $ map (extractLambdaAllocations user bound_outside mempty) ops
      variantAlloc (_, Var v, _) = v `notNameIn` bound_outside
      variantAlloc _ = False
      (variant_allocs, invariant_allocs) =
        M.partition variantAlloc $ kbody_allocs <> mconcat ops_allocs
      badVariant (_, Var v, _) = v `notNameIn` bound_in_kernel
      badVariant _ = False

  case find badVariant $ M.elems variant_allocs of
    Just v ->
      throwError $
        "Cannot handle un-sliceable allocation size: "
          ++ prettyString v
          ++ "\nLikely cause: irregular nested operations inside parallel constructs."
    Nothing ->
      pure ()

  case lvl of
    SegBlock {}
      | not $ null variant_allocs ->
          throwError "Cannot handle invariant allocations in SegBlock."
    _ ->
      pure ()

  if null variant_allocs && null invariant_allocs
    then pure (mempty, (lvl, ops, kbody))
    else do
      (lvl_stms, lvl', grid) <- ensureGridKnown lvl
      allocsForBody variant_allocs invariant_allocs grid space kbody kbody' $
        \alloc_stms kbody'' -> do
          ops'' <- forM ops' $ \op' ->
            localScope (scopeOf op') $ offsetMemoryInLambda op'
          pure (lvl_stms <> alloc_stms, (lvl', ops'', kbody''))
  where
    bound_in_kernel =
      namesFromList (M.keys $ scopeOfSegSpace space)
        <> boundInKernelBody kbody

boundInKernelBody :: KernelBody GPUMem -> Names
boundInKernelBody = namesFromList . M.keys . scopeOf . kernelBodyStms

allocsForBody ::
  Extraction ->
  Extraction ->
  KernelGrid ->
  SegSpace ->
  KernelBody GPUMem ->
  KernelBody GPUMem ->
  (Stms GPUMem -> KernelBody GPUMem -> OffsetM b) ->
  ExpandM b
allocsForBody variant_allocs invariant_allocs grid space kbody kbody' m = do
  (alloc_offsets, alloc_stms) <-
    memoryRequirements
      grid
      space
      (kernelBodyStms kbody)
      variant_allocs
      invariant_allocs

  scope <- askScope
  let scope' = scopeOfSegSpace space <> scope
  either throwError pure $
    runOffsetM scope' alloc_offsets $ do
      kbody'' <- offsetMemoryInKernelBody kbody'
      m alloc_stms kbody''

memoryRequirements ::
  KernelGrid ->
  SegSpace ->
  Stms GPUMem ->
  Extraction ->
  Extraction ->
  ExpandM (RebaseMap, Stms GPUMem)
memoryRequirements grid space kstms variant_allocs invariant_allocs = do
  (num_threads, num_threads_stms) <-
    runBuilder . letSubExp "num_threads" . BasicOp $
      BinOp
        (Mul Int64 OverflowUndef)
        (unCount $ gridNumBlocks grid)
        (unCount $ gridBlockSize grid)

  (invariant_alloc_stms, invariant_alloc_offsets) <-
    inScopeOf num_threads_stms $
      expandedInvariantAllocations
        num_threads
        (gridNumBlocks grid)
        (gridBlockSize grid)
        invariant_allocs

  (variant_alloc_stms, variant_alloc_offsets) <-
    inScopeOf num_threads_stms $
      expandedVariantAllocations
        num_threads
        space
        kstms
        variant_allocs

  pure
    ( invariant_alloc_offsets <> variant_alloc_offsets,
      num_threads_stms <> invariant_alloc_stms <> variant_alloc_stms
    )

type Exp64 = TPrimExp Int64 VName

-- | Identifying the spot where an allocation occurs in terms of its
-- level and unique thread ID.
type User = (SegLevel, [Exp64])

-- | A description of allocations that have been extracted, and how
-- much memory (and which space) is needed.
type Extraction = M.Map VName (User, SubExp, Space)

extractKernelBodyAllocations ::
  User ->
  Names ->
  Names ->
  KernelBody GPUMem ->
  ( KernelBody GPUMem,
    Extraction
  )
extractKernelBodyAllocations lvl bound_outside bound_kernel =
  extractGenericBodyAllocations lvl bound_outside bound_kernel kernelBodyStms $
    \stms kbody -> kbody {kernelBodyStms = stms}

extractBodyAllocations ::
  User ->
  Names ->
  Names ->
  Body GPUMem ->
  (Body GPUMem, Extraction)
extractBodyAllocations user bound_outside bound_kernel =
  extractGenericBodyAllocations user bound_outside bound_kernel bodyStms $
    \stms body -> body {bodyStms = stms}

extractLambdaAllocations ::
  User ->
  Names ->
  Names ->
  Lambda GPUMem ->
  (Lambda GPUMem, Extraction)
extractLambdaAllocations user bound_outside bound_kernel lam =
  (lam {lambdaBody = body'}, allocs)
  where
    (body', allocs) =
      extractBodyAllocations user bound_outside bound_kernel $
        lambdaBody lam

extractGenericBodyAllocations ::
  User ->
  Names ->
  Names ->
  (body -> Stms GPUMem) ->
  (Stms GPUMem -> body -> body) ->
  body ->
  ( body,
    Extraction
  )
extractGenericBodyAllocations user bound_outside bound_kernel get_stms set_stms body =
  let bound_kernel' = bound_kernel <> boundByStms (get_stms body)
      (stms, allocs) =
        runWriter . fmap catMaybes $
          mapM (extractStmAllocations user bound_outside bound_kernel') $
            stmsToList (get_stms body)
   in (set_stms (stmsFromList stms) body, allocs)

expandable, notScalar :: Space -> Bool
expandable (Space "shared") = False
expandable ScalarSpace {} = False
expandable _ = True
notScalar ScalarSpace {} = False
notScalar _ = True

extractStmAllocations ::
  User ->
  Names ->
  Names ->
  Stm GPUMem ->
  Writer Extraction (Maybe (Stm GPUMem))
extractStmAllocations user bound_outside bound_kernel (Let (Pat [patElem]) _ (Op (Alloc size space)))
  | expandable space && expandableSize size
      -- FIXME: the '&& notScalar space' part is a hack because we
      -- don't otherwise hoist the sizes out far enough, and we
      -- promise to be super-duper-careful about not having variant
      -- scalar allocations.
      || (boundInKernel size && notScalar space) = do
      tell $ M.singleton (patElemName patElem) (user, size, space)
      pure Nothing
  where
    expandableSize (Var v) = v `nameIn` bound_outside || v `nameIn` bound_kernel
    expandableSize Constant {} = True
    boundInKernel (Var v) = v `nameIn` bound_kernel
    boundInKernel Constant {} = False
extractStmAllocations user bound_outside bound_kernel stm = do
  e <- mapExpM (expMapper user) $ stmExp stm
  pure $ Just $ stm {stmExp = e}
  where
    expMapper user' =
      (identityMapper @GPUMem)
        { mapOnBody = const $ onBody user',
          mapOnOp = onOp user'
        }

    onBody user' body = do
      let (body', allocs) = extractBodyAllocations user' bound_outside bound_kernel body
      tell allocs
      pure body'

    onOp (_, user_ids) (Inner (SegOp op)) =
      Inner . SegOp <$> mapSegOpM (opMapper user'') op
      where
        user'' =
          (segLevel op, user_ids ++ [le64 (segFlat (segSpace op))])
    onOp _ op = pure op

    opMapper user' =
      identitySegOpMapper
        { mapOnSegOpLambda = onLambda user',
          mapOnSegOpBody = onKernelBody user'
        }

    onKernelBody user' body = do
      let (body', allocs) =
            extractKernelBodyAllocations user' bound_outside bound_kernel body
      tell allocs
      pure body'

    onLambda user' lam = do
      body <- onBody user' $ lambdaBody lam
      pure lam {lambdaBody = body}

genericExpandedInvariantAllocations ::
  (User -> (Shape, [Exp64])) -> Extraction -> ExpandM (Stms GPUMem, RebaseMap)
genericExpandedInvariantAllocations getNumUsers invariant_allocs = do
  -- We expand the invariant allocations by adding an inner dimension
  -- equal to the number of kernel threads.
  (rebases, alloc_stms) <- runBuilder $ mapM expand $ M.toList invariant_allocs

  pure (alloc_stms, mconcat rebases)
  where
    expand (mem, (user, per_thread_size, space)) = do
      let num_users = fst $ getNumUsers user
          allocpat = Pat [PatElem mem $ MemMem space]
      total_size <-
        letExp "total_size" <=< toExp . product $
          pe64 per_thread_size : map pe64 (shapeDims num_users)
      letBind allocpat $ Op $ Alloc (Var total_size) space
      pure $ M.singleton mem $ newBase user

    newBaseThread user _old_shape =
      let (users_shape, user_ids) = getNumUsers user
          dims = map pe64 (shapeDims users_shape)
       in ( flattenIndex dims user_ids,
            product dims
          )

    newBase user@(SegThreadInBlock {}, _) = newBaseThread user
    newBase user@(SegThread {}, _) = newBaseThread user
    newBase user@(SegBlock {}, _) = \_old_shape ->
      let (users_shape, user_ids) = getNumUsers user
          dims = map pe64 (shapeDims users_shape)
       in ( flattenIndex dims user_ids,
            product dims
          )

expandedInvariantAllocations ::
  SubExp ->
  Count NumBlocks SubExp ->
  Count BlockSize SubExp ->
  Extraction ->
  ExpandM (Stms GPUMem, RebaseMap)
expandedInvariantAllocations num_threads (Count num_tblocks) (Count tblock_size) =
  genericExpandedInvariantAllocations getNumUsers
  where
    getNumUsers (SegThread {}, [gtid]) = (Shape [num_threads], [gtid])
    getNumUsers (SegThread {}, [gid, ltid]) = (Shape [num_tblocks, tblock_size], [gid, ltid])
    getNumUsers (SegThreadInBlock {}, [gtid]) = (Shape [num_threads], [gtid])
    getNumUsers (SegThreadInBlock {}, [gid, ltid]) = (Shape [num_tblocks, tblock_size], [gid, ltid])
    getNumUsers (SegBlock {}, [gid]) = (Shape [num_tblocks], [gid])
    getNumUsers user = error $ "getNumUsers: unhandled " ++ show user

expandedVariantAllocations ::
  SubExp ->
  SegSpace ->
  Stms GPUMem ->
  Extraction ->
  ExpandM (Stms GPUMem, RebaseMap)
expandedVariantAllocations _ _ _ variant_allocs
  | null variant_allocs = pure (mempty, mempty)
expandedVariantAllocations num_threads kspace kstms variant_allocs = do
  let sizes_to_blocks = removeCommonSizes variant_allocs
      variant_sizes = map fst sizes_to_blocks

  (slice_stms, offsets, size_sums) <-
    sliceKernelSizes num_threads variant_sizes kspace kstms
  -- Note the recursive call to expand allocations inside the newly
  -- produced kernels.
  slice_stms_tmp <- simplifyStms =<< explicitAllocationsInStms slice_stms
  slice_stms' <- transformStms slice_stms_tmp

  let variant_allocs' :: [(VName, (SubExp, SubExp, Space))]
      variant_allocs' =
        concat $
          zipWith memInfo (map snd sizes_to_blocks) (zip offsets size_sums)
      memInfo blocks (offset, total_size) =
        [(mem, (Var offset, Var total_size, space)) | (mem, space) <- blocks]

  -- We expand the invariant allocations by adding an inner dimension
  -- equal to the sum of the sizes required by different threads.
  (alloc_stms, rebases) <- mapAndUnzipM expand variant_allocs'

  pure (slice_stms' <> stmsFromList alloc_stms, mconcat rebases)
  where
    expand (mem, (_offset, total_size, space)) = do
      let allocpat = Pat [PatElem mem $ MemMem space]
      pure
        ( Let allocpat (defAux ()) $ Op $ Alloc total_size space,
          M.singleton mem newBase
        )

    num_threads' = pe64 num_threads
    gtid = le64 $ segFlat kspace

    -- For the variant allocations, we add an inner dimension,
    -- which is then offset by a thread-specific amount.
    newBase _old_shape =
      (gtid, num_threads')

type Expansion = (Exp64, Exp64)

-- | A map from memory block names to index function embeddings..
type RebaseMap = M.Map VName ([Exp64] -> Expansion)

newtype OffsetM a
  = OffsetM
      ( ReaderT
          (Scope GPUMem)
          (ReaderT RebaseMap (Either String))
          a
      )
  deriving
    ( Applicative,
      Functor,
      Monad,
      HasScope GPUMem,
      LocalScope GPUMem,
      MonadError String
    )

runOffsetM :: Scope GPUMem -> RebaseMap -> OffsetM a -> Either String a
runOffsetM scope offsets (OffsetM m) =
  runReaderT (runReaderT m scope) offsets

askRebaseMap :: OffsetM RebaseMap
askRebaseMap = OffsetM $ lift ask

localRebaseMap :: (RebaseMap -> RebaseMap) -> OffsetM a -> OffsetM a
localRebaseMap f (OffsetM m) = OffsetM $ do
  scope <- ask
  lift $ local f $ runReaderT m scope

lookupNewBase :: VName -> [Exp64] -> OffsetM (Maybe Expansion)
lookupNewBase name x = do
  offsets <- askRebaseMap
  pure $ ($ x) <$> M.lookup name offsets

offsetMemoryInKernelBody :: KernelBody GPUMem -> OffsetM (KernelBody GPUMem)
offsetMemoryInKernelBody kbody = do
  scope <- askScope
  stms' <-
    stmsFromList . snd
      <$> mapAccumLM
        (\scope' -> localScope scope' . offsetMemoryInStm)
        scope
        (stmsToList $ kernelBodyStms kbody)
  pure kbody {kernelBodyStms = stms'}

offsetMemoryInBody :: Body GPUMem -> OffsetM (Body GPUMem)
offsetMemoryInBody (Body dec stms res) = do
  scope <- askScope
  stms' <-
    stmsFromList . snd
      <$> mapAccumLM
        (\scope' -> localScope scope' . offsetMemoryInStm)
        scope
        (stmsToList stms)
  pure $ Body dec stms' res

offsetMemoryInStm :: Stm GPUMem -> OffsetM (Scope GPUMem, Stm GPUMem)
offsetMemoryInStm (Let pat dec e) = do
  e' <- offsetMemoryInExp e
  pat' <-
    offsetMemoryInPat pat
      =<< maybe (throwError "offsetMemoryInStm: ill-typed") pure
      =<< expReturns e'
  scope <- askScope
  -- Try to recompute the index function.  Fall back to creating rebase
  -- operations with the RebaseMap.
  rts <-
    maybe (throwError "offsetMemoryInStm: ill-typed") pure $
      runReader (expReturns e') scope
  let pat'' = Pat $ zipWith pick (patElems pat') rts
      stm = Let pat'' dec e'
  let scope' = scopeOf stm <> scope
  pure (scope', stm)
  where
    pick ::
      PatElem (MemInfo SubExp NoUniqueness MemBind) ->
      ExpReturns ->
      PatElem (MemInfo SubExp NoUniqueness MemBind)
    pick
      (PatElem name (MemArray pt s u _ret))
      (MemArray _ _ _ (Just (ReturnsInBlock m extixfun)))
        | Just ixfun <- instantiateIxFun extixfun =
            PatElem name (MemArray pt s u (ArrayIn m ixfun))
    pick p _ = p

    instantiateIxFun :: ExtIxFun -> Maybe IxFun
    instantiateIxFun = traverse (traverse inst)
      where
        inst Ext {} = Nothing
        inst (Free x) = pure x

offsetMemoryInPat :: Pat LetDecMem -> [ExpReturns] -> OffsetM (Pat LetDecMem)
offsetMemoryInPat (Pat pes) rets = do
  Pat <$> zipWithM onPE pes rets
  where
    onPE
      (PatElem name (MemArray pt shape u (ArrayIn mem _)))
      (MemArray _ _ _ info)
        | Just ixfun <- getIxFun info =
            pure . PatElem name . MemArray pt shape u . ArrayIn mem $
              fmap (fmap unExt) ixfun
    onPE pe _ = do
      new_dec <- offsetMemoryInMemBound (patElemName pe) $ patElemDec pe
      pure pe {patElemDec = new_dec}
    unExt (Ext i) = patElemName (pes !! i)
    unExt (Free v) = v
    getIxFun (Just (ReturnsNewBlock _ _ ixfun)) = Just ixfun
    getIxFun (Just (ReturnsInBlock _ ixfun)) = Just ixfun
    getIxFun _ = Nothing

offsetMemoryInParam :: Param (MemBound u) -> OffsetM (Param (MemBound u))
offsetMemoryInParam fparam = do
  fparam' <- offsetMemoryInMemBound (paramName fparam) $ paramDec fparam
  pure fparam {paramDec = fparam'}

offsetMemoryInMemBound :: VName -> MemBound u -> OffsetM (MemBound u)
offsetMemoryInMemBound v summary@(MemArray pt shape u (ArrayIn mem ixfun)) = do
  embedding <- lookupNewBase mem $ IxFun.shape ixfun
  case embedding of
    Nothing -> pure summary
    Just (o, p) -> do
      let problem =
            throwError . unlines $
              [ "offsetMemoryInMemBound",
                prettyString v,
                prettyString (o, p),
                prettyString ixfun
              ]
      ixfun' <- maybe problem pure $ IxFun.expand o p ixfun
      pure $ MemArray pt shape u $ ArrayIn mem ixfun'
offsetMemoryInMemBound _ summary = pure summary

offsetMemoryInBodyReturns :: BodyReturns -> OffsetM BodyReturns
offsetMemoryInBodyReturns br@(MemArray pt shape u (ReturnsInBlock mem ixfun))
  | Just ixfun' <- isStaticIxFun ixfun = do
      embedding <- lookupNewBase mem $ IxFun.shape ixfun'
      case embedding of
        Nothing -> pure br
        Just (o, p) -> do
          let problem =
                throwError . unlines $
                  [ "offsetMemoryInBodyReturns",
                    prettyString (o, p),
                    prettyString ixfun
                  ]
          ixfun'' <-
            maybe problem pure $
              IxFun.expand (Free <$> o) (fmap Free p) ixfun
          pure $ MemArray pt shape u $ ReturnsInBlock mem ixfun''
offsetMemoryInBodyReturns br = pure br

offsetMemoryInLambda :: Lambda GPUMem -> OffsetM (Lambda GPUMem)
offsetMemoryInLambda lam = do
  body <- inScopeOf lam $ offsetMemoryInBody $ lambdaBody lam
  params <- mapM offsetMemoryInParam $ lambdaParams lam
  pure $ lam {lambdaBody = body, lambdaParams = params}

-- A loop may have memory parameters, and those memory blocks may
-- be expanded.  We assume (but do not check - FIXME) that if the
-- initial value of a loop parameter is an expanded memory block,
-- then so will the result be.
offsetMemoryInLoopParams ::
  [(FParam GPUMem, SubExp)] ->
  ([(FParam GPUMem, SubExp)] -> OffsetM a) ->
  OffsetM a
offsetMemoryInLoopParams merge f = do
  let (params, args) = unzip merge
  localRebaseMap extend $ do
    params' <- mapM offsetMemoryInParam params
    f $ zip params' args
  where
    extend rm = foldl' onParamArg rm merge
    onParamArg rm (param, Var arg)
      | Just x <- M.lookup arg rm =
          M.insert (paramName param) x rm
    onParamArg rm _ = rm

offsetMemoryInExp :: Exp GPUMem -> OffsetM (Exp GPUMem)
offsetMemoryInExp (Loop merge form body) = do
  offsetMemoryInLoopParams merge $ \merge' -> do
    body' <-
      localScope
        (scopeOfFParams (map fst merge') <> scopeOfLoopForm form)
        (offsetMemoryInBody body)
    pure $ Loop merge' form body'
offsetMemoryInExp e = mapExpM recurse e
  where
    recurse =
      (identityMapper @GPUMem)
        { mapOnBody = \bscope -> localScope bscope . offsetMemoryInBody,
          mapOnBranchType = offsetMemoryInBodyReturns,
          mapOnOp = onOp
        }
    onOp (Inner (SegOp op)) =
      Inner . SegOp
        <$> localScope (scopeOfSegSpace (segSpace op)) (mapSegOpM segOpMapper op)
      where
        segOpMapper =
          identitySegOpMapper
            { mapOnSegOpBody = offsetMemoryInKernelBody,
              mapOnSegOpLambda = offsetMemoryInLambda
            }
    onOp op = pure op

---- Slicing allocation sizes out of a kernel.

unAllocGPUStms :: Stms GPUMem -> Either String (Stms GPU.GPU)
unAllocGPUStms = unAllocStms False
  where
    unAllocBody (Body dec stms res) =
      Body dec <$> unAllocStms True stms <*> pure res

    unAllocKernelBody (KernelBody dec stms res) =
      KernelBody dec <$> unAllocStms True stms <*> pure res

    unAllocStms nested = mapM (unAllocStm nested)

    unAllocStm nested stm@(Let pat dec (Op Alloc {}))
      | nested =
          throwError $ "Cannot handle nested allocation: " <> prettyString stm
      | otherwise =
          Let
            <$> unAllocPat pat
            <*> pure dec
            <*> pure (BasicOp (SubExp $ Constant UnitValue))
    unAllocStm _ (Let pat dec e) =
      Let <$> unAllocPat pat <*> pure dec <*> mapExpM unAlloc' e

    unAllocLambda (Lambda params ret body) =
      Lambda (map unParam params) ret <$> unAllocBody body

    unAllocPat (Pat pes) =
      Pat <$> mapM (rephrasePatElem (Right . unMem)) pes

    unAllocOp Alloc {} = Left "unAllocOp: unhandled Alloc"
    unAllocOp (Inner OtherOp {}) = Left "unAllocOp: unhandled OtherOp"
    unAllocOp (Inner GPUBody {}) = Left "unAllocOp: unhandled GPUBody"
    unAllocOp (Inner (SizeOp op)) = pure $ SizeOp op
    unAllocOp (Inner (SegOp op)) = SegOp <$> mapSegOpM mapper op
      where
        mapper =
          identitySegOpMapper
            { mapOnSegOpLambda = unAllocLambda,
              mapOnSegOpBody = unAllocKernelBody
            }

    unParam = fmap unMem

    unT = Right . unMem

    unAlloc' =
      Mapper
        { mapOnBody = const unAllocBody,
          mapOnRetType = unT,
          mapOnBranchType = unT,
          mapOnFParam = Right . unParam,
          mapOnLParam = Right . unParam,
          mapOnOp = unAllocOp,
          mapOnSubExp = Right,
          mapOnVName = Right
        }

unMem :: MemInfo d u ret -> TypeBase (ShapeBase d) u
unMem (MemPrim pt) = Prim pt
unMem (MemArray pt shape u _) = Array pt shape u
unMem (MemAcc acc ispace ts u) = Acc acc ispace ts u
unMem MemMem {} = Prim Unit

unAllocScope :: Scope GPUMem -> Scope GPU.GPU
unAllocScope = M.map unInfo
  where
    unInfo (LetName dec) = LetName $ unMem dec
    unInfo (FParamName dec) = FParamName $ unMem dec
    unInfo (LParamName dec) = LParamName $ unMem dec
    unInfo (IndexName it) = IndexName it

removeCommonSizes :: Extraction -> [(SubExp, [(VName, Space)])]
removeCommonSizes = M.toList . foldl' comb mempty . M.toList
  where
    comb m (mem, (_, size, space)) = M.insertWith (++) size [(mem, space)] m

copyConsumed :: (MonadBuilder m, AliasableRep (Rep m)) => Stms (Rep m) -> m (Stms (Rep m))
copyConsumed stms = do
  let consumed = namesToList $ snd $ snd $ Alias.analyseStms mempty stms
  collectStms_ $ do
    consumed' <- mapM copy consumed
    let substs = M.fromList (zip consumed consumed')
    addStms $ substituteNames substs stms
  where
    copy v = letExp (baseString v <> "_copy") $ BasicOp $ Replicate mempty $ Var v

-- Important for edge cases (#1838) that the Stms here still have the
-- Allocs we are actually trying to get rid of.
sliceKernelSizes ::
  SubExp ->
  [SubExp] ->
  SegSpace ->
  Stms GPUMem ->
  ExpandM (Stms GPU.GPU, [VName], [VName])
sliceKernelSizes num_threads sizes space kstms = do
  kstms' <- either throwError pure $ unAllocGPUStms kstms
  let num_sizes = length sizes
      i64s = replicate num_sizes $ Prim int64

  kernels_scope <- asks unAllocScope

  (max_lam, _) <- flip runBuilderT kernels_scope $ do
    xs <- replicateM num_sizes $ newParam "x" (Prim int64)
    ys <- replicateM num_sizes $ newParam "y" (Prim int64)
    (zs, stms) <- localScope (scopeOfLParams $ xs ++ ys) $
      collectStms $
        forM (zip xs ys) $ \(x, y) ->
          fmap subExpRes . letSubExp "z" . BasicOp $
            BinOp (SMax Int64) (Var $ paramName x) (Var $ paramName y)
    pure $ Lambda (xs ++ ys) i64s (mkBody stms zs)

  flat_gtid_lparam <- newParam "flat_gtid" (Prim (IntType Int64))

  size_lam' <- localScope (scopeOfSegSpace space) . fmap fst . flip runBuilderT kernels_scope $
    GPU.simplifyLambda <=< mkLambda [flat_gtid_lparam] $ do
      -- Even though this SegRed is one-dimensional, we need to
      -- provide indexes corresponding to the original potentially
      -- multi-dimensional construct.
      let (kspace_gtids, kspace_dims) = unzip $ unSegSpace space
          new_inds =
            unflattenIndex
              (map pe64 kspace_dims)
              (pe64 $ Var $ paramName flat_gtid_lparam)
      zipWithM_ letBindNames (map pure kspace_gtids) =<< mapM toExp new_inds
      mapM_ addStm =<< copyConsumed kstms'
      pure $ subExpsRes sizes

  ((maxes_per_thread, size_sums), slice_stms) <- flip runBuilderT kernels_scope $ do
    pat <-
      basicPat <$> replicateM num_sizes (newIdent "max_per_thread" $ Prim int64)

    w <-
      letSubExp "size_slice_w"
        =<< foldBinOp (Mul Int64 OverflowUndef) (intConst Int64 1) (segSpaceDims space)

    thread_space_iota <-
      letExp "thread_space_iota" $
        BasicOp $
          Iota w (intConst Int64 0) (intConst Int64 1) Int64
    let red_op =
          SegBinOp
            Commutative
            max_lam
            (replicate num_sizes $ intConst Int64 0)
            mempty
    lvl <- segThread "segred"

    addStms
      =<< mapM renameStm
      =<< nonSegRed lvl pat w [red_op] size_lam' [thread_space_iota]

    size_sums <- forM (patNames pat) $ \threads_max ->
      letExp "size_sum" $
        BasicOp $
          BinOp (Mul Int64 OverflowUndef) (Var threads_max) num_threads

    pure (patNames pat, size_sums)

  pure (slice_stms, maxes_per_thread, size_sums)

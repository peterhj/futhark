{-# LANGUAGE FlexibleContexts, ScopedTypeVariables #-}
module Futhark.Tools
  (
    module Futhark.Construct

  , nonuniqueParams
  , nonuniqueFParams
  , redomapToMapAndReduce
  , sequentialStreamWholeArray
  , singletonChunkRedLikeStreamLambda
  , partitionChunkedLambdaParameters
  , intraproceduralTransformation
  , boundInBody
  )
where

import Control.Applicative
import Control.Monad.Identity
import Control.Monad.State
import Data.Monoid
import qualified Data.HashMap.Lazy as HM

import Prelude

import Futhark.Representation.AST
import qualified Futhark.Representation.AST.Annotations as Annotations
import Futhark.MonadFreshNames
import Futhark.Construct

nonuniqueParams :: (MonadFreshNames m, Bindable lore) =>
                   [LParam lore] -> m ([LParam lore], [Binding lore])
nonuniqueParams params =
  modifyNameSource $ runState $ liftM fst $ runBinderEmptyEnv $
  collectBindings $ forM params $ \param -> do
    param_name <- newVName $ baseString (paramName param) ++ "_nonunique"
    let param' = Param param_name $ paramType param
    bindingIdentTypes [paramIdent param'] $
      letBindNames_ [(paramName param,BindVar)] $
      PrimOp $ Copy $ paramName param'
    return param'

nonuniqueFParams :: (MonadFreshNames m, Bindable lore) =>
                    [FParam lore] -> m ([FParam lore], [Binding lore])
nonuniqueFParams params =
  modifyNameSource $ runState $ liftM fst $ runBinderEmptyEnv $
  collectBindings $ forM params $ \param ->
  if unique (paramDeclType param) then do
    param_name <- newVName $ baseString (paramName param) ++ "_nonunique"
    let param' = Param param_name $ paramDeclType param `setUniqueness` Nonunique
    bindingIdentTypes [paramIdent param'] $
      letBindNames_ [(paramName param,BindVar)] $
      PrimOp $ Copy $ paramName param'
    return param'
  else
    return param

-- | Turns a binding of a @redomap@ into two seperate bindings, a
-- @map@ binding and a @reduce@ binding (returned in that order).
--
-- Reuses the original pattern for the @reduce@, and creates a new
-- pattern with new 'Ident's for the result of the @map@. Does /not/
-- add the new idents to the 'TypeEnv'.
--
-- Only handles a 'Pattern' with an empty 'patternContextElements'
redomapToMapAndReduce :: (MonadFreshNames m, Bindable lore) =>
                         PatternT lore -> Annotations.Exp lore
                      -> ( Certificates, SubExp
                         , LambdaT lore, LambdaT lore, [SubExp]
                         , [VName])
                      -> m (Binding lore, Binding lore)
redomapToMapAndReduce (Pattern [] patelems) lore
                      (certs, outersz, redlam, redmap_lam, accs, arrs) = do
  let (acc_patelems, arr_patelems) = splitAt (length accs) patelems
  map_accpat <- mapM accMapPatElem acc_patelems
  map_arrpat <- mapM arrMapPatElem arr_patelems
  let map_pat = map_accpat ++ map_arrpat
      map_bnd = mkLet [] map_pat $
                LoopOp $ Map certs outersz newmap_lam arrs
      red_args = zip accs $ map (identName . fst) map_accpat
      red_bnd = Let (Pattern [] patelems) lore $
                LoopOp $ Reduce certs outersz redlam red_args
  return (map_bnd, red_bnd)
  where
    accMapPatElem pe = do
      let (Ident vn tp) = patElemIdent pe
      let tp' = arrayOfRow tp outersz
      i <- newIdent (baseString vn ++ "_map_acc") tp'
      return (i, patElemBindage pe)
    arrMapPatElem pe =
      return (patElemIdent pe, patElemBindage pe)

    newmap_lam =
      let tobnd = take (length accs) $ map paramIdent $ lambdaParams redmap_lam
          params' = drop (length accs) $ lambdaParams redmap_lam
          bndaccs = zipWith (\i acc -> mkLet' []  [i] (PrimOp $ SubExp acc))
                            tobnd accs
          body = lambdaBody redmap_lam
          bnds' = bndaccs ++ bodyBindings body
          body' = body {bodyBindings = bnds'}
      in redmap_lam { lambdaBody = body', lambdaParams = params' }
redomapToMapAndReduce _ _ _ =
  error "redomapToMapAndReduce does not handle an empty 'patternContextElements'"

sequentialStreamWholeArrayBindings :: Bindable lore =>
                                      SubExp -> [SubExp]
                                   -> ExtLambdaT lore -> [VName]
                                   -> ([Binding lore], [SubExp])
sequentialStreamWholeArrayBindings width accs lam arrs =
  let (chunk_param, acc_params, arr_params) =
        partitionChunkedFoldParameters (length accs) $ extLambdaParams lam
      chunk_bnd = mkLet' [] [paramIdent chunk_param] $ PrimOp $ SubExp width
      acc_bnds = [ mkLet' [] [paramIdent acc_param] $ PrimOp $ SubExp acc
                 | (acc_param, acc) <- zip acc_params accs ]
      arr_bnds = [ mkLet' [] [paramIdent arr_param] $
                   PrimOp $ Reshape [] (map DimCoercion $ arrayDims $ paramType arr_param) arr
                 | (arr_param, arr) <- zip arr_params arrs ]

  in (chunk_bnd :
      acc_bnds ++
      arr_bnds ++
      bodyBindings (extLambdaBody lam),

      bodyResult $ extLambdaBody lam)

sequentialStreamWholeArray :: (MonadBinder m, Bindable (Lore m)) =>
                              Pattern (Lore m)
                           -> Certificates
                           -> SubExp -> [SubExp]
                           -> ExtLambdaT (Lore m) -> [VName]
                           -> m ()
sequentialStreamWholeArray pat cs width nes fun arrs = do
  let (body_bnds,res) = sequentialStreamWholeArrayBindings width nes fun arrs
      reshapeRes t (Var v)
        | null (arrayDims t) = PrimOp $ SubExp $ Var v
        | otherwise          = shapeCoerce cs (arrayDims t) v
      reshapeRes _ se        = PrimOp $ SubExp se
      res_bnds =
        [ mkLet' [] [ident] $ reshapeRes (identType ident) se
        | (ident,se) <- zip (patternValueIdents pat) res]

  mapM_ addBinding body_bnds
  shapemap <- shapeMapping (patternValueTypes pat) <$> mapM subExpType res
  forM_ (HM.toList shapemap) $ \(name,se) ->
    when (name `elem` patternContextNames pat) $
      addBinding =<< mkLetNames' [name] (PrimOp $ SubExp se)
  mapM_ addBinding res_bnds

singletonChunkRedLikeStreamLambda :: (Bindable lore, MonadFreshNames m) =>
                                     [Type] -> ExtLambda lore -> m (Lambda lore)
singletonChunkRedLikeStreamLambda acc_ts lam = do
  -- The accumulator params are OK, but we need array params without
  -- the chunk part.
  let (chunk_param, acc_params, arr_params) =
        partitionChunkedFoldParameters (length acc_ts) $ extLambdaParams lam
  unchunked_arr_params <- forM arr_params $ \arr_param ->
    Param <$>
    newVName (baseString (paramName arr_param) <> "_unchunked") <*>
    pure (rowType $ paramType arr_param)
  let chunk_name = paramName chunk_param
      chunk_bnd = mkLet' [] [paramIdent chunk_param] $
                  PrimOp $ SubExp $ Constant $ IntVal 1
      arr_bnds = [ mkLet' [] [paramIdent arr_param] $
                   PrimOp $ Replicate (Var chunk_name) $
                   Var $ paramName unchunked_arr_param |
                   (arr_param, unchunked_arr_param) <-
                     zip arr_params unchunked_arr_params ]
      unchunked_body = insertBindings (chunk_bnd:arr_bnds) $ extLambdaBody lam
  return Lambda { lambdaBody = unchunked_body
                , lambdaParams = acc_params <> unchunked_arr_params
                , lambdaReturnType = acc_ts
                , lambdaIndex = extLambdaIndex lam
                }

partitionChunkedFoldParameters :: Int -> [Param attr]
                               -> (Param attr, [Param attr], [Param attr])
partitionChunkedFoldParameters _ [] =
  error "partitionChunkedFoldParameters: lambda takes no parameters"
partitionChunkedFoldParameters num_accs (chunk_param : params) =
  let (acc_params, arr_params) = splitAt num_accs params
  in (chunk_param, acc_params, arr_params)

partitionChunkedLambdaParameters :: [Param attr]
                               -> (Param attr, [Param attr])
partitionChunkedLambdaParameters [] =
  error "partitionChunkedLambdaParameters: lambda takes no parameters"
partitionChunkedLambdaParameters (chunk_param : params) =
  (chunk_param, params)

intraproceduralTransformation :: MonadFreshNames m =>
                                 (FunDec fromlore -> State VNameSource (FunDec tolore))
                              -> Prog fromlore -> m (Prog tolore)
intraproceduralTransformation ft prog =
  modifyNameSource $ runState $ Prog <$> mapM ft (progFunctions prog)

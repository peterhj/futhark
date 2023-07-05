// Start of context.h

// Eventually it would be nice to move the context definition in here
// instead of generating it in the compiler.  For now it defines
// various helper functions that must be available.

// Internal functions.

static void set_error(struct futhark_context* ctx, char *error) {
  //lock_lock(&ctx->error_lock);
  if (ctx->error == NULL) {
    ctx->error = error;
  } else {
    free(error);
  }
  //lock_unlock(&ctx->error_lock);
}

// XXX: should be static, but used in ispc_util.h
void lexical_realloc_error(struct futhark_context* ctx, size_t new_size) {
  set_error(ctx,
            msgprintf("Failed to allocate memory.\nAttempted allocation: %12lld bytes\n",
                      (long long) new_size));
}

static int lexical_realloc(struct futhark_context *ctx,
                           unsigned char **ptr,
                           int64_t *old_size,
                           int64_t new_size) {
  unsigned char *new = realloc(*ptr, (size_t)new_size);
  if (new == NULL) {
    lexical_realloc_error(ctx, new_size);
    return FUTHARK_OUT_OF_MEMORY;
  } else {
    *ptr = new;
    *old_size = new_size;
    return FUTHARK_SUCCESS;
  }
}

static void free_all_in_free_list(struct futhark_context* ctx) {
  fl_mem mem;
  free_list_pack(&ctx->free_list);
  while (free_list_first(&ctx->free_list, (fl_mem*)&mem) == 0) {
    free((void*)mem);
  }
}

static int is_small_alloc(size_t size) {
  return size < 1024*1024;
}

static void host_unify(struct futhark_context* ctx,
                       const char *lhs_tag, const char *rhs_tag) {
  // FIXME
}

static void host_alloc(struct futhark_context* ctx,
                       size_t size, const char* tag, size_t* size_out, void** mem_out) {
  const char *tag_out = NULL;
  if (is_small_alloc(size) || free_list_find(&ctx->free_list, size, tag, size_out, (fl_mem*)mem_out, &tag_out) != 0) {
    *size_out = size;
    *mem_out = malloc(size);
    host_unify(ctx, tag, tag_out);
  }
}

static void host_free(struct futhark_context* ctx,
                      size_t size, const char* tag, void* mem) {
  // Small allocations are handled by malloc()s own free list.  The
  // threshold here is kind of arbitrary, but seems to work OK.
  // Larger allocations are mmap()ed/munmapped() every time, which is
  // very slow, and Futhark programs tend to use a few very large
  // allocations.
  if (is_small_alloc(size)) {
    free(mem);
  } else {
    free_list_insert(&ctx->free_list, size, (fl_mem)mem, tag);
  }
}

struct futhark_context_config* futhark_context_config_new(void) {
  struct futhark_context_config* cfg = malloc(sizeof(struct futhark_context_config));
  if (cfg == NULL) {
    return NULL;
  }
  cfg->in_use = 0;
  cfg->debugging = 0;
  cfg->profiling = 0;
  cfg->logging = 0;
  cfg->cache_fname = NULL;
  cfg->num_tuning_params = num_tuning_params;
  cfg->tuning_params = malloc(cfg->num_tuning_params * sizeof(int64_t));
  memcpy(cfg->tuning_params, tuning_param_defaults,
         cfg->num_tuning_params * sizeof(int64_t));
  cfg->tuning_param_names = tuning_param_names;
  cfg->tuning_param_vars = tuning_param_vars;
  cfg->tuning_param_classes = tuning_param_classes;
  backend_context_config_setup(cfg);
  return cfg;
}

void futhark_context_config_free(struct futhark_context_config* cfg) {
  printf("rts: futhark_context_config_free: ...\n");
  assert(!cfg->in_use);
  backend_context_config_teardown(cfg);
  free(cfg->tuning_params);
  free(cfg);
  printf("rts: futhark_context_config_free: done\n");
}

struct futhark_context* futhark_context_new(struct futhark_context_config* cfg) {
  printf("rts: futhark_context_new: ...\n");
  struct futhark_context* ctx = malloc(sizeof(struct futhark_context));
  if (ctx == NULL) {
    return NULL;
  }
  assert(!cfg->in_use);
  ctx->cfg = cfg;
  ctx->cfg->in_use = 1;
  //create_lock(&ctx->error_lock);
  //create_lock(&ctx->lock);
  printf("rts: futhark_context_new: init free list...\n");
  free_list_init(&ctx->free_list);
  ctx->peak_mem_usage_default = 0;
  ctx->cur_mem_usage_default = 0;
  ctx->constants = malloc(sizeof(struct constants));
  ctx->detail_memory = cfg->debugging;
  ctx->debugging = cfg->debugging;
  ctx->logging = cfg->logging;
  ctx->profiling = cfg->profiling;
  ctx->profiling_paused = 0;
  ctx->error = NULL;
  ctx->log = stderr;
  printf("rts: futhark_context_new: setup backend...\n");
  if (backend_context_setup(ctx) == 0) {
    printf("rts: futhark_context_new: set tuning params...\n");
    set_tuning_params(ctx);
    printf("rts: futhark_context_new: setup program...\n");
    setup_program(ctx);
    printf("rts: futhark_context_new: init constants...\n");
    init_constants(ctx);
    printf("rts: futhark_context_new: clear caches...\n");
    (void)futhark_context_clear_caches(ctx);
    //printf("rts: futhark_context_new: sync...\n");
    //(void)futhark_context_sync(ctx);
  }
  printf("rts: futhark_context_new: done\n");
  return ctx;
}

void futhark_context_free(struct futhark_context* ctx) {
  printf("rts: futhark_context_free: free constants...\n");
  free_constants(ctx);
  printf("rts: futhark_context_free: teardown program...\n");
  teardown_program(ctx);
  printf("rts: futhark_context_free: teardown backend ctx...\n");
  backend_context_teardown(ctx);
  printf("rts: futhark_context_free: free all...\n");
  free_all_in_free_list(ctx);
  printf("rts: futhark_context_free: destroy free list...\n");
  free_list_destroy(&ctx->free_list);
  printf("rts: futhark_context_free: free constants...\n");
  free(ctx->constants);
  //printf("rts: futhark_context_free: free locks...\n");
  //free_lock(&ctx->lock);
  //free_lock(&ctx->error_lock);
  printf("rts: futhark_context_free: unset cfg in_use...\n");
  ctx->cfg->in_use = 0;
  printf("rts: futhark_context_free: free ctx...\n");
  free(ctx);
  printf("rts: futhark_context_free: done\n");
}

void futhark_context_reset(struct futhark_context* ctx) {
  printf("rts: futhark_context_reset: ...\n");
  free_all_in_free_list(ctx);
  free_list_destroy(&ctx->free_list);
  free_list_init(&ctx->free_list);
  backend_context_reset(ctx);
  printf("rts: futhark_context_reset: done\n");
}

// End of context.h

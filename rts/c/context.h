// Start of context.h

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
  (ctx->cfg->mem_unify)(lhs_tag, rhs_tag);
}

static void host_alloc(struct futhark_context* ctx,
                       size_t size, const char* tag, size_t* size_out, void** mem_out) {
  const char *tag_out = NULL;
  if (is_small_alloc(size) || free_list_find(&ctx->free_list, size, tag, size_out, (fl_mem*)mem_out, &tag_out) != 0) {
    *size_out = size;
    int ret = (ctx->cfg->mem_alloc)(mem_out, size, tag_out);
    assert(ret == 0);
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
    (ctx->cfg->mem_free)(mem);
  } else {
    free_list_insert(&ctx->free_list, size, (fl_mem)mem, tag);
  }
}

static void add_event(struct futhark_context* ctx,
                      const char* name,
                      char* description,
                      void* data,
                      event_report_fn f) {
  if (ctx->logging) {
    fprintf(ctx->log, "Event: %s\n%s\n", name, description);
  }
  add_event_to_list(&ctx->event_list, name, description, data, f);
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
  if (getenv("CACTI_FUTHARK_TRACE") != NULL) {
    cfg->tracing = 1;
  } else {
    cfg->tracing = 0;
  }
  if (getenv("CACTI_FUTHARK_PEDANTIC") != NULL) {
    cfg->pedantic = 1;
  } else {
    cfg->pedantic = 0;
  }
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
  int tracing = cfg->tracing;
  if (tracing) printf("TRACE: rts: futhark_context_config_free: ...\n");
  assert(!cfg->in_use);
  backend_context_config_teardown(cfg);
  free(cfg->cache_fname);
  free(cfg->tuning_params);
  free(cfg);
  if (tracing) printf("TRACE: rts: futhark_context_config_free: done\n");
}

void futhark_context_config_set_mem_alloc(struct futhark_context_config *cfg, void *ptr) {
  cfg->mem_alloc = ptr;
}

void futhark_context_config_set_mem_free(struct futhark_context_config *cfg, void *ptr) {
  cfg->mem_free = ptr;
}

void futhark_context_config_set_mem_unify(struct futhark_context_config *cfg, void *ptr) {
  cfg->mem_unify = ptr;
}

struct futhark_context* futhark_context_new(struct futhark_context_config* cfg) {
  if (cfg->tracing) printf("TRACE: rts: futhark_context_new: ...\n");
  struct futhark_context* ctx = malloc(sizeof(struct futhark_context));
  if (ctx == NULL) {
    return NULL;
  }
  assert(!cfg->in_use);
  ctx->cfg = cfg;
  ctx->cfg->in_use = 1;
  //create_lock(&ctx->error_lock);
  //create_lock(&ctx->lock);
  if (cfg->tracing) printf("TRACE: rts: futhark_context_new: init free list...\n");
  free_list_init(&ctx->free_list);
  event_list_init(&ctx->event_list);
  ctx->peak_mem_usage_default = 0;
  ctx->cur_mem_usage_default = 0;
  ctx->constants = malloc(sizeof(struct constants));
  ctx->debugging = cfg->debugging;
  ctx->logging = cfg->logging;
  ctx->detail_memory = cfg->logging;
  ctx->profiling = cfg->profiling;
  ctx->profiling_paused = 0;
  ctx->error = NULL;
  ctx->log = stderr;
  if (cfg->tracing) printf("TRACE: rts: futhark_context_new: set tuning params...\n");
  set_tuning_params(ctx);
  if (cfg->tracing) printf("TRACE: rts: futhark_context_new: setup backend...\n");
  if (backend_context_setup(ctx) == 0) {
    if (cfg->tracing) printf("TRACE: rts: futhark_context_new: setup program...\n");
    setup_program(ctx);
    if (cfg->tracing) printf("TRACE: rts: futhark_context_new: init constants...\n");
    init_constants(ctx);
    if (cfg->tracing) printf("TRACE: rts: futhark_context_new: clear caches...\n");
    (void)futhark_context_clear_caches(ctx);
    //if (cfg->tracing) printf("TRACE: rts: futhark_context_new: sync...\n");
    //(void)futhark_context_sync(ctx);
  }
  if (cfg->tracing) printf("TRACE: rts: futhark_context_new: done\n");
  return ctx;
}

void futhark_context_free(struct futhark_context* ctx) {
  struct futhark_context_config* cfg = ctx->cfg;
  if (cfg->tracing) printf("TRACE: rts: futhark_context_free: free constants...\n");
  free_constants(ctx);
  if (cfg->tracing) printf("TRACE: rts: futhark_context_free: teardown program...\n");
  teardown_program(ctx);
  if (cfg->tracing) printf("TRACE: rts: futhark_context_free: teardown backend ctx...\n");
  backend_context_teardown(ctx);
  if (cfg->tracing) printf("TRACE: rts: futhark_context_free: free all...\n");
  free_all_in_free_list(ctx);
  if (cfg->tracing) printf("TRACE: rts: futhark_context_free: destroy free list...\n");
  free_list_destroy(&ctx->free_list);
  if (cfg->tracing) printf("TRACE: rts: futhark_context_free: free event list...\n");
  event_list_free(&ctx->event_list);
  if (cfg->tracing) printf("TRACE: rts: futhark_context_free: free constants...\n");
  free(ctx->constants);
  if (cfg->tracing) printf("TRACE: rts: futhark_context_free: free error...\n");
  free(ctx->error);
  //if (cfg->tracing) printf("TRACE: rts: futhark_context_free: free locks...\n");
  //free_lock(&ctx->lock);
  //free_lock(&ctx->error_lock);
  if (cfg->tracing) printf("TRACE: rts: futhark_context_free: unset cfg in_use...\n");
  ctx->cfg->in_use = 0;
  if (cfg->tracing) printf("TRACE: rts: futhark_context_free: free ctx...\n");
  free(ctx);
  if (cfg->tracing) printf("TRACE: rts: futhark_context_free: done\n");
}

int futhark_context_trace(struct futhark_context* ctx) {
  return ctx->cfg->tracing;
}

const char* futhark_context_error(struct futhark_context* ctx) {
  return ctx->error;
}

void futhark_context_reset(struct futhark_context* ctx) {
  if (ctx->cfg->tracing) printf("TRACE: rts: futhark_context_reset: ...\n");
  if (ctx->cfg->pedantic) {
    free_constants(ctx);
    init_constants(ctx);
  }
  if (ctx->cfg->tracing) printf("TRACE: rts: futhark_context_reset: done\n");
}

void futhark_context_release(struct futhark_context* ctx) {
  if (ctx->cfg->tracing) printf("TRACE: rts: futhark_context_release: ...\n");
  free_all_in_free_list(ctx);
  //free_list_destroy(&ctx->free_list);
  //free_list_init(&ctx->free_list);
  backend_context_release(ctx);
  if (ctx->cfg->tracing) printf("TRACE: rts: futhark_context_release: done\n");
}

// End of context.h

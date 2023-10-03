// Start of miniserver.h.

typedef int (*entry_point_fn)(struct futhark_context*, void**, void**);

struct entry_point {
  const char *name;
  entry_point_fn f;
};

struct futhark_prog {
  // Last entry point identified by NULL name.
  struct entry_point *entry_points;
};

int futhark_context_trace(struct futhark_context *ctx);

// End of miniserver.h.

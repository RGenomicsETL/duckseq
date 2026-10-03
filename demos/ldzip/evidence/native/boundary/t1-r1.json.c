/* Compact selected-cell payload; SQL row 0 seeds columns without stored cells. */
typedef struct { int32_t row, q; } ld_dense_cell;
typedef struct {
  ld_dense_cell *cells;
  uint64_t len, cap;
  int64_t n, col, scale;
  int initialized, failed;
} ld_dense_column_state;

void ld_dense_column_step(ld_dense_column_state *st, int64_t row, int64_t col,
                          int64_t q, int64_t n, int64_t scale) {
  uint64_t next_cap;
  ld_dense_cell *p;
  if (st->failed) return;
  if (n < 1 || n > INT32_MAX || row < 0 || row > n || col < 1 || col > n ||
      scale < 1 || scale > INT32_MAX) {
    st->failed = 1;
    return;
  }
  if (!st->initialized) {
    st->n = n;
    st->col = col;
    st->scale = scale;
    st->initialized = 1;
  } else if (st->n != n || st->col != col || st->scale != scale) {
    st->failed = 1;
    return;
  }
  if (row == 0) {
    if (q != 0) st->failed = 1;
    return;
  }
  if (q < -scale || q > scale || st->len >= (uint64_t)st->n) {
    st->failed = 1;
    return;
  }
  if (st->len == st->cap) {
    if (st->cap == 0) {
      next_cap = st->n < 64 ? (uint64_t)st->n : 64;
    } else {
      if (st->cap > UINT64_MAX / 2) {
        st->failed = 1;
        return;
      }
      next_cap = st->cap * 2;
      if (next_cap > (uint64_t)st->n) next_cap = (uint64_t)st->n;
    }
    if (next_cap <= st->cap || next_cap > UINT64_MAX / sizeof(ld_dense_cell)) {
      st->failed = 1;
      return;
    }
    p = ducktinycc_realloc(st->cells, next_cap * sizeof(ld_dense_cell));
    if (!p) {
      st->failed = 1;
      return;
    }
    st->cells = p;
    st->cap = next_cap;
  }
  st->cells[st->len].row = (int32_t)row;
  st->cells[st->len].q = (int32_t)q;
  st->len++;
}

void ld_dense_column_combine(ld_dense_column_state *into, ld_dense_column_state *from) {
  uint64_t k;
  if (into->failed || from->failed) {
    into->failed = 1;
    return;
  }
  if (!from->initialized) return;
  if (!into->initialized) {
    into->n = from->n;
    into->col = from->col;
    into->scale = from->scale;
    into->initialized = 1;
  } else if (into->n != from->n || into->col != from->col ||
             into->scale != from->scale) {
    into->failed = 1;
    return;
  }
  for (k = 0; k < from->len; k++) {
    ld_dense_column_step(into, from->cells[k].row, into->col,
                         from->cells[k].q, into->n, into->scale);
    if (into->failed) return;
  }
}

int ld_dense_column_build(ld_dense_column_state *st, ducktinycc_list_t *out) {
  uint64_t k, bytes;
  double *values;
  out->ptr = 0;
  out->len = 0;
  if (st->failed || !st->initialized || st->n < 1 || st->n > INT32_MAX ||
      st->col < 1 || st->col > st->n || st->scale < 1 || st->scale > INT32_MAX ||
      st->len > st->cap || st->len > (uint64_t)st->n ||
      (uint64_t)st->n > UINT64_MAX / sizeof(double)) return 0;
  for (k = 0; k < st->len; k++) {
    if (st->cells[k].row < 1 || st->cells[k].row > st->n ||
        st->cells[k].q < -st->scale || st->cells[k].q > st->scale) return 0;
  }
  bytes = (uint64_t)st->n * sizeof(double);
  /* The native consumer releases this owned buffer after consumption. */
  values = ducktinycc_malloc(bytes);
  if (!values) return 0;
  for (k = 0; k < (uint64_t)st->n; k++) values[k] = 0.0;
  for (k = 0; k < st->len; k++) {
    float decoded = (float)st->cells[k].q / (float)st->scale;
    values[st->cells[k].row - 1] = (double)decoded;
  }
  values[st->col - 1] = 1.0;
  out->ptr = values;
  out->len = (uint64_t)st->n;
  return 1;
}

int ld_dense_column_final(ld_dense_column_state *st, double *out) {
  ducktinycc_list_t values = {0};
  uint64_t k; double total = 0;
  if (!ld_dense_column_build(st, &values)) return 0;
  for (k = 0; k < values.len; k++) total += ((const double *)values.ptr)[k];
  ducktinycc_free((void *)values.ptr);
  *out = total; return 1;
}
void ld_dense_column_destroy(ld_dense_column_state *st) {
  ducktinycc_free(st->cells);
  st->cells = 0;
  st->len = 0;
  st->cap = 0;
}

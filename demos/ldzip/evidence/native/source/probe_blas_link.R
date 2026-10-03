#!/usr/bin/env Rscript
# ABI/linkage check only; these tiny GEMMs do not establish performance.
source("measure_native.R")
header <- '#define USE_FC_LEN_T
/* Only real BLAS is called; this avoids an unused C99 complex declaration. */
typedef struct { double r, i; } ld_blas_complex;
#define BLAS_complex ld_blas_complex
#include <R_ext/BLAS.h>
#include <dlfcn.h>
'
body <- '  const char no = \'N\';
  const BLAS_INT m=2, n=2, k=3, lda=2, ldb=3, ldc=2;
  const double alpha=1.0, beta=0.0;
  const double a[6]={1,2,3,4,5,6};
  const double b[6]={7,8,9,10,11,12};
  double c[4]={0,0,0,0};
'
provider <- sessionInfo()$BLAS
stopifnot(length(provider) == 1L, file.exists(provider))
con <- dbConnect(duckdb(config = list(allow_unsigned_extensions = "true")), dbdir = ":memory:")
tryCatch({
  dbExecute(con, paste("LOAD", dbQuoteString(con, normalizePath(extension_file))))
  for (mode in c("explicit_blas", "dlopen_provider")) {
    entry <- "F77_CALL(dgemm)"
    setup <- ""
    cleanup <- ""
    library <- "blas"
    if (mode == "dlopen_provider") {
      library <- "c"  # This glibc exports dlopen/dlsym/dlclose from libc.
      setup <- paste0(
        "  void *handle=dlopen(\"", provider, "\",RTLD_NOW|RTLD_LOCAL);\n",
        "  void *symbol; __typeof__(&F77_CALL(dgemm)) routine;\n",
        "  if (!handle) return 0;\n",
        "  symbol=dlsym(handle,\"dgemm_\");\n",
        "  if (!symbol || sizeof(routine)!=sizeof(symbol)) { dlclose(handle); return 0; }\n",
        "  memcpy(&routine,&symbol,sizeof(routine));\n")
      entry <- "routine"
      cleanup <- "  dlclose(handle);\n"
    }
    code <- paste0(header, "int ld_blas_link_check(void) {\n", body, setup,
      "  ", entry, "(&no,&no,&m,&n,&k,&alpha,a,&lda,b,&ldb,&beta,c,&ldc FCONE FCONE);\n",
      cleanup, "  return c[0]==76.0 && c[1]==100.0 && c[2]==103.0 && c[3]==136.0;\n}\n")
    sql_name <- paste0("ld_blas_", mode)
    registered <- dbGetQuery(con, paste0(
      "SELECT * FROM tcc_module(mode:='quick_compile',symbol:='ld_blas_link_check',sql_name:=",
      dbQuoteString(con, sql_name), ",return_type:='i32',arg_types:=[]::VARCHAR[],include_path:=",
      dbQuoteString(con, R.home("include")), ",library:=", dbQuoteString(con, library),
      ",source:=", dbQuoteString(con, code), ")"))
    if (!isTRUE(registered$ok)) stop(paste(unlist(registered), collapse = " | "))
    stopifnot(dbGetQuery(con, paste0("SELECT ", sql_name, "() AS ok"))$ok == 1L)
    cat("PASS", mode, "all four DGEMM entries, column-major, R BLAS_INT/FCONE ABI\n")
  }
  reference <- matrix(c(1,2,3,4,5,6), 2, 3) %*% matrix(c(7,8,9,10,11,12), 3, 2)
  stopifnot(identical(as.numeric(reference), c(76,100,103,136)))
  cat("R BLAS provider:", provider, "\nR LAPACK provider:", sessionInfo()$LAPACK, "\n")
}, finally = dbDisconnect(con, shutdown = TRUE))

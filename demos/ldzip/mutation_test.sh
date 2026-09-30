#!/usr/bin/env bash
set -euo pipefail
Rscript --vanilla - <<'RS'
parity_breaks <- function(expected, mutant, label) {
  if (identical(expected, mutant)) stop(sprintf("Mutation did not break parity: %s", label))
  cat(sprintf("PASS mutation breaks parity: %s\n", label))
}

scale <- 127
x <- 0.5 / scale
correct <- sign(x) * floor(abs(x) * scale + 0.5) / scale
wrong_round <- round(x * scale) / scale
parity_breaks(correct, wrong_round, "ties-to-even quantization")

pairs <- data.frame(i = c(1L, 2L), j = c(2L, 1L), r_q = c(0.75, 0.75))
off_by_one <- transform(pairs, i = i + 1L)
parity_breaks(pairs, off_by_one, "one-based index shift")

upper_only <- subset(pairs, i <= j)
parity_breaks(pairs, upper_only, "upper-only storage loses reverse lookup")

min_abs <- 1e-4
r <- 5e-4
correct_threshold <- if (abs(r) >= min_abs) r else 0
wrong_threshold <- if (abs(r) >= 1e-3) r else 0
parity_breaks(correct_threshold, wrong_threshold, "wrong threshold")

variants <- data.frame(idx = 1:2, id = c("rs-test_A_C", "rs-test_A_G"))
query <- "rs-test_A_G"
correct_id <- variants[variants$id == query, , drop = FALSE]
wrong_id <- variants[grepl("^rs-test", variants$id), , drop = FALSE]
parity_breaks(correct_id, wrong_id, "ID lookup ignoring allele template")
RS

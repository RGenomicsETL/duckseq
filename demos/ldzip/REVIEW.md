# LDZip performance review

## Conclusion

Dense extraction pays for an avoidable full-matrix copy in R as well as the SQL-to-R sparse materialization. Build memory reflects a general-purpose, parallel join-and-sort pipeline rather than LDZip's streaming compressor. Those losses are real on the measured workloads. The apparent large random-pair win needs a fair rerun: the comparator groups LDZip requests along the wrong axis and SQL returns encoded nullable values rather than decoded zero-filled values.

The [native measurements](NATIVE_REPORT.md) separately test SQL-resident dense matrices. At 5,000 variants/16-bit, TinyCC takes 1,039 ms on one thread or 734 ms on four threads, versus LDZip's 109 ms R-matrix endpoint. Constructing and consuming the columns inside C takes 103/39.5 ms but does not return a complete retained matrix. The endpoints return different results. Composite export, SQL retention, buffer lifetime and consumption all differ; the diagnostic does not attribute their individual costs.

This review checks the source at duckseq commit `34973d5` and pinned LDZip commit `f8e363af03b2101b04e56b142595a16a060856b6`. Diagnostic probes used R 4.6.0, DuckDB R 1.5.5 and 20 DuckDB threads. They are mechanism checks, separate from the report's budgeted, peak-RSS benchmark.

## Findings

### High: dense matrix assembly copies another 200 MB

In [`bench_query.R`](bench_query.R), lines 79–84 fetch the sparse result, allocate a dense matrix, scatter the values and call `diag(m) <- 1`. `Rprofmem()` and `tracemem()` identify that last call as a second full-matrix allocation.

For the 4×, 16-bit, leading 5,000-variant window:

| Representation or allocation | Bytes |
|---|---:|
| Sparse R data frame, 579,166 stored rows | 9,267,640 |
| Dense R matrix, including object overhead | 200,000,216 |
| Allocation for the matrix payload | 200,000,048 |
| Additional allocation at `diag<-` | 200,000,048 |

A diagnostic using linear indices for the scatter and diagonal produced only one allocation of at least 64 MiB and exactly matched LDZip's full dense matrix. An unordered query with the original assembly still made the second allocation. Removing the SQL sort alone therefore does not remove this copy.

Linear-index assembly uses:

```r
m <- matrix(0, size, size)
m[result$i + (result$j - 1L) * size] <- result$r
m[seq.int(1L, size * size, by = size + 1L)] <- 1
```

This assembly has not been measured under the full protocol; the report's dense-extraction numbers use the original assembly. LDZip's native `getSubMatrix()` writes decoded values directly into the caller's zero-filled matrix (`cpp/src/ldzipmatrix.cpp`, lines 484–515); avoiding the R copy does not remove the DBI intermediate or establish a general advantage.

### High: random pairs are grouped along the wrong LDZip axis

`bench_query.R`, lines 70–71, uses `order(query$i)`. LDZip's `fetchLD()` passes its second argument as native columns. Native `getPairwise()` groups adjacent equal columns, then expects sorted rows within each column (`cpp/src/ldzipmatrix.cpp`, lines 564–579 and 423–439).

Use `order(query$j, query$i)` and restore original query order after fetching. On the 4×/16-bit fixture, three fresh diagnostic processes per ordering returned these times for 10,000 requests, including sorting and restoring order:

| Ordering | Replicate 1 | Replicate 2 | Replicate 3 |
|---|---:|---:|---:|
| Row-only | 747 ms | 666 ms | 686 ms |
| Column, then row | 23 ms | 22 ms | 23 ms |

Every decoded vector matched a SQL query with float32-equivalent decoding and zero fill exactly. These probes do not measure peak RSS or rerun the entire scale/bit-depth matrix; they establish that the existing comparator misses LDZip's batched access path. The report's 700 ms versus 30 ms pair cell is not evidence of an inherent engine advantage.

### High: the pair benchmark returns different value contracts

`bench_query.R`, lines 55–57, returns `qid,r_q` through a left join. Missing pairs are `NULL` and values remain quantized integers. LDZip returns decoded correlations and zero-fills absent pairs. It also returns variant identifiers. The benchmark does not compare these outputs.

A fair decoded-value query needs the same float32 rounding and zero fill as the parity checks:

```sql
CAST(CAST(coalesce(l.r_q, 0) AS REAL) / 32767 AS REAL)
```

That scale is for 16-bit input; 8-bit input uses 127. Compare all results in query order, retain equivalent identifiers, and rerun both paths. An encoded sparse lookup is also a legitimate workload if labelled as such; it is not equivalent to returning decoded correlations.

### Medium: tag timings include different API and setup work

DuckDB executes one join for 100 tags; LDZip calls `getNeighbors()` 100 times (`bench_query.R`, lines 58–60 and 72–74). LDZip resolves positions and regions through SQLite even for numeric tag inputs before the native lookup. Its SQLite index is required but not built by `measure_queries.sh`; `ldzip compress` timing also excludes that index.

The current timings describe these application paths, not equivalent native tag kernels. Report single-tag and batched workloads separately, and measure compression, `buildIndex()` and ready-for-query setup as distinct stages. A clean benchmark workspace must explicitly create the index.

### Medium: build RSS is a pipeline cost, with operator attribution still open

[`build.sql`](build.sql) materializes variants and joined pairs, expands both triangles plus the diagonal, and sorts before Parquet output (lines 4–22 and 36–50). [`build.sh`](build.sh) leaves DuckDB threads and memory limit at their defaults. LDZip's compressor writes its native representation through a streaming path.

The report records 4×/16-bit build RSS of 665.6 MiB versus 18.8 MiB. SQL is faster at that scale, 0.60 s versus 0.80 s; build-time loss is confined to the smallest scale, not universal. Both implementations store full matrices in this comparison, so attributing the gap to SQL having both triangles would be incorrect.

Profile the build operators and repeat with explicit thread and memory settings. Lower concurrency can reduce memory at a throughput cost; a tighter memory limit may introduce spilling. A streaming native builder is an alternative, but its complexity is not justified by these probes alone.

### Medium: dense and layout coverage is narrower than the input ladder

Every dense request uses `seq_len(size)` (`bench_query.R`, lines 48–50), so the same leading 1,000- or 5,000-variant window is queried inside successively larger files. This tests sensitivity to surrounding file size, not arbitrary genomic windows. The layout sweep is tuned on 1×/8-bit input and then applied to all scales and bit depths.

Add leading, middle and trailing windows with their stored-cell densities. Confirm the selected layout at both bit depths before claiming a general optimum. The CLI submatrix path only streams sparse rows; its timing cannot stand in for either dense-matrix path.

## Reproduce the diagnostic checks

The full-region artifacts must already exist; [`full_test.sh`](full_test.sh) prepares and checks them. These commands create fresh R processes and do not modify the benchmark TSVs:

```sh
cd demos/ldzip
export R_LIBS_USER="$PWD/.rlib:$PWD/.cache/R/library${R_LIBS_USER:+:$R_LIBS_USER}"

for mode in original unordered linear; do
  Rscript --vanilla profile_dense.R work/derived/region-4x 16 5000 "$mode"
done

for mode in original column_grouped; do
  for rep in 1 2 3; do
    Rscript --vanilla profile_pairs.R work/derived/region-4x 16 "$rep" "$mode"
  done
done

./test.sh
```

The fixture suite passes 8/16-bit quantization, LDZip decoded parity, tag and lookup checks, dense extraction, all six mutation checks, and the colliding-allele-key check. The full 1×/2×/4× performance protocol was not rerun for this review.

## Execution boundary

The dense R result in `bench_query.R` is a compatibility endpoint for LDZipMatrix consumers, not a requirement of the SQL implementation. For SQL consumers, keep selected cells and matrix computation in DuckDB. Reuse a compatible matrix/linear-algebra extension where its input representation and operations fit; use a small DuckTinyCC kernel for the quantized-cell-to-matrix assembly when needed. Assembly is decoding and indexed writes, not a BLAS operation.

The budgeted DuckTinyCC endpoint constructs `DOUBLE[]` columns in DuckDB, with R receiving only scalar metrics. Admission checks verify every cell at 1,000/2,000/4,000/5,000 variants, both bit depths and 1/4 threads; small matrices also match LDZip exactly. The [native report](NATIVE_REPORT.md) retains the built-in SQL resource failures and distinguishes SQL-resident matrices from R-matrix compatibility. The installed extension lacked aggregate registration, so the deployed artifact's capabilities must be checked explicitly.

Native aggregate partial states should retain compact selected cells or bounded blocks, not a complete dense matrix per worker. DuckTinyCC copies composite results into DuckDB-owned output vectors, so avoiding R does not establish zero-copy execution or a speed advantage. Measure the native construction and its actual consumer together.

For an R-only consumer such as SuSiE, make the final R-matrix transfer explicit and measure it separately. Rducks also owns a native query-stream path: it fetches a DuckDB chunk, materializes its vectors into R batches, then destroys the chunk. A chunk-to-native-buffer consumer would act before that R-batch materialization and complete borrowed-vector access before chunk destruction. That is a distinct streaming/GEMM design, not an R callback or a promise of zero-copy matrix layout. The public R-batch endpoint still copies values; R API work stays on the recorded R thread.

The predeclared [native measurement protocol](NATIVE_PROTOCOL.md) separates SQL-resident matrix construction/consumption from the R compatibility endpoint. A direct C-buffer checksum diagnostic measures the constructor without exporting all cells as SQL lists. TinyCC can explicitly link BLAS or `dlopen()` R's actual OpenBLAS provider: `probe_blas_link.R` checks every entry of a small DGEMM using R's Fortran ABI. Optimized BLAS/LAPACK and libc supply the hot loops; TinyCC supplies the glue. GEMM performance and the proposed query-chunk handoff are not measured.

## Recommended order of work

1. Correct pair ordering and returned-value semantics, add batch parity checks, explicitly prepare the tag index, and rerun the comparator.
2. Benchmark a chunk-to-native-buffer consumer with optimized BLAS/LAPACK and an equivalent computational reference. Bound scratch/state memory, verify layout and ownership, and measure both the computation and its retained result. Compare an existing matrix extension where its representation fits.
3. Keep the dense R endpoint as a separately labelled compatibility workload. Apply linear-index assembly there and measure the final transfer, latency and peak RSS independently of native SQL execution.
4. Profile build joins and sorts with declared concurrency before considering a native builder or another storage layout.

Selection stays in Parquet and SQL, numeric kernels in native code, and R is an optional consumer. LDZip is faster in every measured R-matrix extraction here.

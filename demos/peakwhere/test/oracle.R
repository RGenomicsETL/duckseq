# Independent oracle for the thymus data. It shares no code with the SQL pipeline
# and uses base R only: read the GFF3 by hand, build every category interval, and give
# each peak centre the best (lowest) priority among the intervals that contain it.
# Slow on purpose. Defaults to the bundled chr19 data and expected fixture.
#
# Run from the repository root: Rscript test/oracle.R [annotation.gff3.gz peak-dir output.json]

args <- commandArgs(TRUE)
stopifnot(length(args) %in% c(0L, 3L))
annotation <- if (length(args) == 0L) "examples/gencode.vM25.basic.chr19.gff3.gz" else args[1]
peak_directory <- if (length(args) == 0L) "examples" else args[2]
output <- if (length(args) == 0L) "test/fixtures/thymus-expected.json" else args[3]

promoter_upstream <- 1000L
promoter_downstream <- 1000L
categories <- c("promoter", "utr5", "utr3", "exon", "intron", "intergenic")

read_gz_lines <- function(path) {
  con <- gzfile(path, "rt")
  on.exit(close(con))
  readLines(con)
}

gff_attributes <- function(column) {
  lapply(strsplit(column, ";", fixed = TRUE), function(pairs) {
    pairs <- pairs[grepl("=", pairs, fixed = TRUE)]
    keys <- sub("=.*$", "", pairs)
    values <- vapply(sub("^[^=]*=", "", pairs), URLdecode, character(1), USE.NAMES = FALSE)
    setNames(values, keys)
  })
}

lines <- read_gz_lines(annotation)
lines <- lines[!startsWith(lines, "#")]
fields <- do.call(rbind, strsplit(lines, "\t", fixed = TRUE))
gff <- data.frame(
  chrom = fields[, 1],
  type = tolower(fields[, 3]),
  s = as.integer(fields[, 4]) - 1L, # 0-based half-open from here on
  e = as.integer(fields[, 5]),
  strand = fields[, 7],
  stringsAsFactors = FALSE
)
attrs <- gff_attributes(fields[, 9])
gff$id <- vapply(attrs, function(a) if ("ID" %in% names(a)) a[["ID"]] else NA_character_, "")
parents <- lapply(attrs, function(a) if ("Parent" %in% names(a)) strsplit(a[["Parent"]], ",")[[1]] else character())

# One row per (parent, part) for exons and UTRs.
part_types <- c("exon", "five_prime_utr", "three_prime_utr")
part_rows <- which(gff$type %in% part_types)
parts <- do.call(rbind, lapply(part_rows, function(i) {
  if (length(parents[[i]]) == 0L) return(NULL)
  data.frame(tx = parents[[i]], type = gff$type[i], chrom = gff$chrom[i],
             s = gff$s[i], e = gff$e[i], stringsAsFactors = FALSE)
}))

# A transcript is any feature that is the Parent of an exon; the first feature with a
# given ID supplies its span and strand.
transcripts <- unique(parts$tx[parts$type == "exon"])
by_id <- gff[!is.na(gff$id) & !duplicated(gff$id), ]
tx <- by_id[match(transcripts, by_id$id), ]

tss <- ifelse(tx$strand == "+", tx$s, tx$e - 1L)
promoter_s <- ifelse(tx$strand == "+", tss - promoter_upstream, tss - promoter_downstream)
promoter_e <- ifelse(tx$strand == "+", tss + promoter_downstream + 1L, tss + promoter_upstream + 1L)
part_priority <- c(five_prime_utr = 2L, three_prime_utr = 3L, exon = 4L)
kept_parts <- parts[parts$tx %in% transcripts, ]

intervals <- rbind(
  data.frame(chrom = tx$chrom, s = pmax(0L, promoter_s), e = promoter_e, priority = 1L),
  data.frame(chrom = tx$chrom, s = tx$s, e = tx$e, priority = 5L),
  data.frame(chrom = kept_parts$chrom, s = kept_parts$s, e = kept_parts$e,
             priority = unname(part_priority[kept_parts$type]))
)
intervals_by_chrom <- split(intervals, intervals$chrom)

category_of <- function(chrom, x) {
  iv <- intervals_by_chrom[[chrom]]
  if (is.null(iv)) return(6L)
  hit <- iv$priority[iv$s <= x & x < iv$e]
  if (length(hit) == 0L) 6L else min(hit)
}

peak_files <- sort(list.files(peak_directory, pattern = "\\.narrowPeak\\.gz$", full.names = TRUE))
counts <- lapply(peak_files, function(path) {
  peak <- do.call(rbind, strsplit(read_gz_lines(path), "\t", fixed = TRUE))
  s <- as.integer(peak[, 2])
  e <- as.integer(peak[, 3])
  centre <- s + (e - s) %/% 2L
  category <- mapply(category_of, peak[, 1], centre, USE.NAMES = FALSE)
  setNames(tabulate(category, nbins = length(categories)), categories)
})
names(counts) <- vapply(strsplit(basename(peak_files), "_", fixed = TRUE), `[`, "", 2L)

json_counts <- function(n, indent) {
  body <- paste0(indent, '  "', names(n), '": ', n, collapse = ",\n")
  paste0("{\n", body, "\n", indent, "}")
}
json <- paste0(
  "{\n",
  '  "_comment": "Peak-centre counts from test/oracle.R, promoter 1000/1000, all transcripts.",\n',
  '  "counts_centre": {\n',
  paste0('    "', names(counts), '": ', vapply(counts, json_counts, "", indent = "    "), collapse = ",\n"),
  "\n  }\n}\n"
)
writeLines(json, output, sep = "")
invisible(lapply(names(counts), function(n) cat(n, counts[[n]], "\n")))

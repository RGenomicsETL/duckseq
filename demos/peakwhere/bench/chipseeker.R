# A fresh R process constructs one TxDb and annotates all five files.
args <- commandArgs(TRUE)
request <- jsonlite::read_json(args[1], simplifyVector = TRUE)
suppressPackageStartupMessages(library(ChIPseeker))
suppressPackageStartupMessages(library(GenomicFeatures))
categories <- c("promoter", "utr5", "utr3", "exon", "intron", "intergenic")
clock <- function() unname(proc.time()["elapsed"])
start <- clock()
txdb <- txdbmaker::makeTxDbFromGFF(request$annotation, format = "gff3")
partition_end <- clock()
counts <- list()
input_n <- dropped <- downstream <- list()
for (i in seq_len(nrow(request$peaks))) {
  label <- request$peaks$label[i]
  bed <- read.table(request$peaks$url[i], sep = "\t", header = FALSE, comment.char = "",
                    quote = "", colClasses = c("character", "integer", "integer", rep("NULL", 7)))
  centre <- bed[[2]] + (bed[[3]] - bed[[2]]) %/% 2L + 1L
  peaks <- GenomicRanges::GRanges(bed[[1]], IRanges::IRanges(centre, width = 1L))
  annotation <- as.data.frame(ChIPseeker::annotatePeak(
    peaks, TxDb = txdb, level = "transcript", tssRegion = c(-1000, 1000),
    genomicAnnotationPriority = c("Promoter", "5UTR", "3UTR", "Exon", "Intron", "Intergenic"),
    ignoreDownstream = TRUE, verbose = FALSE
  ))$annotation
  category <- sub(" .*", "", annotation)
  mapping <- c(Promoter = "promoter", `5'` = "utr5", `3'` = "utr3", Exon = "exon",
               Intron = "intron", Downstream = "intergenic", Distal = "intergenic")
  mapped <- unname(mapping[category])
  stopifnot(!anyNA(mapped))
  counts[[label]] <- as.list(setNames(tabulate(match(mapped, categories), length(categories)), categories))
  input_n[[label]] <- nrow(bed)
  dropped[[label]] <- nrow(bed) - length(annotation)
  downstream[[label]] <- sum(category == "Downstream")
  stopifnot(dropped[[label]] >= 0L, sum(unlist(counts[[label]])) + dropped[[label]] == nrow(bed))
}
end <- clock()
packages <- c("ChIPseeker", "txdbmaker", "GenomicFeatures", "GenomicRanges", "IRanges", "rtracklayer")
jsonlite::write_json(list(
  seconds = list(partition = partition_end - start, count = end - partition_end, total = end - start),
  counts_centre = counts, input_n = input_n, dropped = dropped, downstream = downstream,
  transcripts = length(GenomicFeatures::transcripts(txdb)),
  R = R.version.string, bioconductor = as.character(BiocManager::version()),
  packages = setNames(lapply(packages, function(p) as.character(packageVersion(p))), packages),
  session = capture.output(sessionInfo())
), args[2], auto_unbox = TRUE, pretty = TRUE)

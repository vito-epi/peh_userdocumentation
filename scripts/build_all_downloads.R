# scripts/build_all_downloads.R
# Loop over config/dois.yml and run the existing zenodo_rds_to_xlsx.R engine for each DOI.

suppressPackageStartupMessages({
  library(yaml)
})

# 1) Load the wrapper from step 2
source("scripts/build_downloads_for_doi.R")

# 2) Read config
cfg <- yaml::read_yaml("config/dois.yml")

if (is.null(cfg$dois) || length(cfg$dois) == 0) {
  stop("No DOIs found in config/dois.yml. Expected:\n\ndois:\n  - doi: 10.5281/zenodo.xxxxx\n")
}

# 3) Ensure downloads folder exists (engine will create subfolders)
dir.create("downloads", showWarnings = FALSE, recursive = TRUE)

# Helper: make DOI folder name the same way as in your engine (safe_name-ish)
safe_doi_folder <- function(doi) {
  x <- as.character(doi)
  x[x == "" | is.na(x)] <- "unknown"
  x <- gsub("[\\\\/:*?\"<>|]", "_", x)
  x <- gsub("[[:cntrl:]]", "_", x)
  x <- gsub("\\s+", " ", x)
  trimws(x)
}

# Keep a list of processed dois (for rebuilding downloads/index.html at end)
processed <- character(0)

# 4) Run build for each DOI
for (x in cfg$dois) {
  
  # Support both formats: "- doi: ..." OR "- id: ..."
  doi <- x$doi
  if (is.null(doi) || !nzchar(doi)) doi <- x$id
  
  if (is.null(doi) || !nzchar(doi)) next
  
  message("======================================================")
  message("Building downloads for DOI: ", doi)
  message("======================================================")
  
  # Optional rds_key support (only if you ever add it later)
  rds_key <- ""
  if (!is.null(x$rds_key) && nzchar(x$rds_key)) rds_key <- x$rds_key
  
  # Call wrapper (sets env + sources your existing engine script)
  build_downloads_for_doi(doi = doi, rds_key = rds_key)
  
  processed <- c(processed, doi)
}

# 5) (Re)generate a robust top-level downloads/index.html
#    This avoids relying on whichever DOI ran last.
processed <- unique(processed)

index_path <- file.path("downloads", "index.html")

lines <- c(
  "<!doctype html><html><head><meta charset='utf-8'><title>Downloads</title></head><body>",
  "<h1>Downloads</h1>",
  "<p>Select a DOI folder to browse generated Excel exports.</p>",
  "<ul>",
  vapply(processed, function(doi) {
    folder <- safe_doi_folder(doi)
    # Link points to the DOI folder index.html (created by your engine)
    sprintf("<li><a href='%s/'>%s</a></li>", folder, doi)
  }, character(1)),
  "</ul>",
  "</body></html>"
)

writeLines(lines, index_path)

message("All DOIs processed.")
message("Wrote top-level index: ", normalizePath(index_path, winslash = "/", mustWork = FALSE))

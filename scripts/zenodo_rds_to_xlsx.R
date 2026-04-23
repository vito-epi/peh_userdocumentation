# scripts/zenodo_rds_to_xlsx.R
# Build Excel exports from a Zenodo-hosted .rds (nested lists -> data.frames)
#
# Output structure:
# downloads/<DOI>/<top-level-element>/<nested-path>/<dataframe-name>.xlsx

suppressPackageStartupMessages({
  library(zen4R)      # DOI -> record metadata/files [2](https://rdrr.io/cran/zen4R/man/get_zenodo.html)[3](https://rdrr.io/cran/zen4R/man/ZenodoRecord.html)
  library(openxlsx)   # Excel writing [7](https://joshuasturm.github.io/openxlsx/index.html)
  library(httr)       # robust download with user-agent
  library(tools)
})

doi <- Sys.getenv("ZENODO_DOI", "10.5281/zenodo.19682162")
# Optional: specify exact filename/key inside Zenodo record if multiple .rds files exist
# (e.g. "my_export.rds"). Leave empty to auto-pick first *.rds
rds_key_preferred <- Sys.getenv("ZENODO_RDS_KEY", "")

# Optional: if you hit rate limits, you can set a token for higher limits (public records work without)
zenodo_token <- Sys.getenv("ZENODO_API_KEY", "")

# ------------ helpers ------------

safe_name <- function(x, max_len = 80) {
  x <- as.character(x)
  x[is.na(x) | x == ""] <- "unnamed"
  # replace invalid path chars across OS
  x <- gsub("[\\\\/:*?\"<>|]", "_", x)
  x <- gsub("[[:cntrl:]]", "_", x)
  x <- gsub("\\s+", " ", x)
  x <- trimws(x)
  ifelse(nchar(x) > max_len, substr(x, 1, max_len), x)
}

ensure_dir <- function(path) dir.create(path, showWarnings = FALSE, recursive = TRUE)

download_to_file <- function(url, dest, token = "", ua = "PEH-DocSite/1.0 (https://vito-epi.github.io/peh_userdocumentation/)") {
  ensure_dir(dirname(dest))
  req <- httr::GET(
    url,
    httr::user_agent(ua),
    if (nzchar(token)) httr::add_headers(Authorization = paste("Bearer", token)) else NULL
  )
  httr::stop_for_status(req)
  writeBin(httr::content(req, as = "raw"), dest)
  dest
}

# Extract a usable download URL from zenodo file object.
# zenodo API commonly provides file links; if not, fall back to /api/records/<id>/files/<key>/content pattern. [5](https://ror.readme.io/docs/zenodo)[6](https://davetang.org/muse/2024/04/12/downloading-data-from-zenodo-using-zenodo_get/)
file_download_url <- function(record_id, file_obj) {
  # Try common locations
  if (!is.null(file_obj$links$self) && nzchar(file_obj$links$self)) return(file_obj$links$self)
  if (!is.null(file_obj$links$download) && nzchar(file_obj$links$download)) return(file_obj$links$download)
  if (!is.null(file_obj$links$content) && nzchar(file_obj$links$content)) return(file_obj$links$content)
  
  key <- file_obj$key %||% file_obj$filename %||% file_obj$name
  if (is.null(key) || !nzchar(key)) stop("Cannot determine file key/filename from Zenodo record metadata.")
  key_enc <- utils::URLencode(key, reserved = TRUE)
  sprintf("https://zenodo.org/api/records/%s/files/%s/content", record_id, key_enc)
}

`%||%` <- function(a, b) if (!is.null(a)) a else b

# Recursively traverse object; whenever a data.frame is found -> write Excel
write_df_excel <- function(df, out_xlsx, sheet_name = "data") {
  wb <- createWorkbook()
  sheet_name <- safe_name(sheet_name, max_len = 31) # Excel sheet name max 31
  addWorksheet(wb, sheet_name)
  writeDataTable(wb, sheet = sheet_name, x = df, withFilter = TRUE)
  freezePane(wb, sheet = sheet_name, firstRow = TRUE)
  setColWidths(wb, sheet = sheet_name, cols = 1:max(1, ncol(df)), widths = "auto")
  ensure_dir(dirname(out_xlsx))
  saveWorkbook(wb, out_xlsx, overwrite = TRUE)
}

# Depth-first traversal: any list nesting depth; create directories for list nodes
walk_nested <- function(x, base_dir, path_parts = character(), counters = new.env(parent = emptyenv())) {
  if (is.data.frame(x)) {
    # decide filename from last path part (if meaningful) else use counter
    leaf <- if (length(path_parts)) tail(path_parts, 1) else "data"
    leaf <- safe_name(leaf, max_len = 80)
    
    # avoid collisions: same leaf in same folder
    key <- paste(c(base_dir, head(path_parts, -1), leaf), collapse = "||")
    if (is.null(counters[[key]])) counters[[key]] <- 0L
    counters[[key]] <- counters[[key]] + 1L
    idx <- counters[[key]]
    
    fname <- if (idx == 1L) sprintf("%s.xlsx", leaf) else sprintf("%s_%03d.xlsx", leaf, idx)
    out <- file.path(base_dir, head(path_parts, -1), fname)
    write_df_excel(x, out_xlsx = out, sheet_name = leaf)
    return(invisible(NULL))
  }
  
  if (is.list(x)) {
    nms <- names(x)
    if (is.null(nms)) nms <- rep("", length(x))
    
    for (i in seq_along(x)) {
      nm <- nms[[i]]
      nm_use <- if (nzchar(nm)) nm else sprintf("item_%03d", i)
      nm_use <- safe_name(nm_use, max_len = 80)
      
      # Always create directory levels for list nodes (your requirement)
      walk_nested(x[[i]], base_dir = base_dir, path_parts = c(path_parts, nm_use), counters = counters)
    }
    return(invisible(NULL))
  }
  
  # ignore other object types
  invisible(NULL)
}

# ------------ main ------------

message("Resolving Zenodo record for DOI: ", doi)
z <- zen4R::get_zenodo(doi)  # accepts DOI/concept DOI [2](https://rdrr.io/cran/zen4R/man/get_zenodo.html)

# zen4R returns a ZenodoRecord object (R6). We will try to access id and files generically. [3](https://rdrr.io/cran/zen4R/man/ZenodoRecord.html)
record <- z
record_id <- NULL

# Try common access patterns
if (!is.null(record$id)) record_id <- record$id
if (is.null(record_id) && "getId" %in% names(record)) {
  # if it’s an R6 method
  try(record_id <- record$getId(), silent = TRUE)
}
if (is.null(record_id)) stop("Could not determine Zenodo record id from zen4R object.")

files <- record$files
if (is.null(files) || length(files) == 0) stop("No files found in Zenodo record metadata.")

# pick .rds file
pick <- NULL
if (nzchar(rds_key_preferred)) {
  pick <- Filter(function(f) {
    key <- f$key %||% f$filename %||% f$name
    isTRUE(!is.null(key) && identical(key, rds_key_preferred))
  }, files)
  if (length(pick) == 0) stop("ZENODO_RDS_KEY set but not found in Zenodo record files.")
  pick <- pick[[1]]
} else {
  rds_files <- Filter(function(f) {
    key <- f$key %||% f$filename %||% f$name
    !is.null(key) && grepl("\\.rds$", key, ignore.case = TRUE)
  }, files)
  if (length(rds_files) == 0) stop("No .rds file found in Zenodo record files.")
  pick <- rds_files[[1]]
}

pick_key <- pick$key %||% pick$filename %||% pick$name
dl_url <- file_download_url(record_id, pick)

message("Downloading RDS file: ", pick_key)
tmp_rds <- tempfile(fileext = ".rds")
download_to_file(dl_url, tmp_rds, token = zenodo_token)

obj <- readRDS(tmp_rds)

# Output root folder uses DOI string as requested
doi_dir <- file.path("downloads", safe_name(doi, max_len = 120))

# scripts/zenodo_rds_to_xlsx.R
# Zenodo DOI -> record via REST API -> download .rds -> nested lists -> data.frames -> Excel files

suppressPackageStartupMessages({
  library(httr)
  library(jsonlite)
  library(openxlsx)
})

# scripts/zenodo_rds_to_xlsx.R
# Zenodo DOI -> record via REST API -> download .rds -> nested lists -> data.frames -> Excel files

suppressPackageStartupMessages({
  library(httr)
  library(jsonlite)
  library(openxlsx)
})

doi <- Sys.getenv("ZENODO_DOI", "10.5281/zenodo.19682162")
rds_key_preferred <- Sys.getenv("ZENODO_RDS_KEY", "")   # optional exact filename in Zenodo record
zenodo_token <- Sys.getenv("ZENODO_API_KEY", "")        # optional for higher rate limits

ua <- "PEH-DocSite/1.0 (https://vito-epi.github.io/peh_userdocumentation/)"

`%||%` <- function(a, b) if (!is.null(a)) a else b

safe_name <- function(x, max_len = 80) {
  x <- as.character(x)
  x[is.na(x) | x == ""] <- "unnamed"
  x <- gsub("[\\\\/:*?\"<>|]", "_", x)
  x <- gsub("[[:cntrl:]]", "_", x)
  x <- gsub("\\s+", " ", x)
  x <- trimws(x)
  ifelse(nchar(x) > max_len, substr(x, 1, max_len), x)
}

ensure_dir <- function(path) {
  if (!is.null(path) && nzchar(path) && !is.na(path)) {
    dir.create(path, showWarnings = FALSE, recursive = TRUE)
  }
}

zenodo_headers <- function() {
  h <- c(`User-Agent` = ua)
  if (nzchar(zenodo_token)) h <- c(h, Authorization = paste("Bearer", zenodo_token))
  h
}

get_json <- function(url, query = NULL) {
  resp <- httr::RETRY(
    "GET", url,
    query = query,
    httr::add_headers(.headers = zenodo_headers()),
    times = 5
  )
  httr::stop_for_status(resp)
  jsonlite::fromJSON(httr::content(resp, as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
}

# --- Robust DOI -> Zenodo record resolver ---
query1 <- sprintf('pids.doi.identifier:"%s"', doi)
js <- get_json("https://zenodo.org/api/records", query = list(q = query1, size = 1))

hits <- js$hits$hits
if (is.null(hits) || length(hits) == 0) {
  # 2) Fallback: resolve DOI via doi.org -> Zenodo landing page -> extract record id
  doi_url <- if (grepl("^https?://", doi)) doi else paste0("https://doi.org/", doi)
  
  resp <- httr::RETRY(
    "GET", doi_url,
    httr::add_headers(.headers = c(`User-Agent` = ua)),
    times = 5
  )
  httr::stop_for_status(resp)
  
  final_url <- resp$url
  recid <- sub(".*zenodo\\.org/(records|record)/([0-9]+).*", "\\2", final_url)
  
  if (!grepl("^[0-9]+$", recid)) {
    stop("Could not resolve DOI to a Zenodo record id. Final URL was: ", final_url)
  }
  
  rec <- get_json(paste0("https://zenodo.org/api/records/", recid))
} else {
  rec <- hits[[1]]
}

message("Resolved Zenodo record id: ", rec$id)


record_id <- rec$id
files <- rec$files
if (is.null(files) || length(files) == 0) stop("Zenodo record has no files: ", doi)

# 2) Pick the RDS file
pick <- NULL
if (nzchar(rds_key_preferred)) {
  pick <- Filter(function(f) {
    key <- f$key %||% f$filename %||% f$name
    !is.null(key) && identical(key, rds_key_preferred)
  }, files)
  if (length(pick) == 0) stop("ZENODO_RDS_KEY was set but not found in record files.")
  pick <- pick[[1]]
} else {
  rds_files <- Filter(function(f) {
    key <- f$key %||% f$filename %||% f$name
    !is.null(key) && grepl("\\.rds$", key, ignore.case = TRUE)
  }, files)
  if (length(rds_files) == 0) stop("No .rds file found in Zenodo record.")
  pick <- rds_files[[1]]
}

pick_key <- pick$key %||% pick$filename %||% pick$name
dl_url <- pick$links$self %||% pick$links$download %||% pick$links$content
if (is.null(dl_url) || !nzchar(dl_url)) {
  # fallback: known Zenodo API file content pattern [6](https://ror.readme.io/docs/zenodo)
  dl_url <- sprintf("https://zenodo.org/api/records/%s/files/%s/content", record_id, URLencode(pick_key, reserved = TRUE))
}

message("Downloading RDS: ", pick_key)
tmp <- tempfile(fileext = ".rds")
bin <- GET(
  dl_url,
  user_agent(ua),
  if (nzchar(zenodo_token)) add_headers(Authorization = paste("Bearer", zenodo_token)) else NULL
)
stop_for_status(bin)
writeBin(content(bin, as = "raw"), tmp)

obj <- readRDS(tmp)
if (!is.list(obj)) stop("Top-level object in RDS is not a list; cannot apply requested folder structure.")

# 3) Write Excel from any-depth nested lists -> data.frames
write_df_excel <- function(df, out_xlsx, sheet_name = "data") {
  wb <- createWorkbook()
  sheet <- safe_name(sheet_name, max_len = 31)
  addWorksheet(wb, sheet)
  writeDataTable(wb, sheet = sheet, x = df, withFilter = TRUE)
  freezePane(wb, sheet, firstRow = TRUE)
  setColWidths(wb, sheet, cols = 1:max(1, ncol(df)), widths = "auto")
  ensure_dir(dirname(out_xlsx))
  saveWorkbook(wb, out_xlsx, overwrite = TRUE)
}

walk_nested <- function(x, base_dir, path_parts = character(), counters = new.env(parent = emptyenv())) {
  if (is.data.frame(x)) {
    leaf <- if (length(path_parts)) tail(path_parts, 1) else "data"
    leaf <- safe_name(leaf, 80)
    
    key <- paste(c(base_dir, head(path_parts, -1), leaf), collapse = "||")
    if (is.null(counters[[key]])) counters[[key]] <- 0L
    counters[[key]] <- counters[[key]] + 1L
    idx <- counters[[key]]
    
    fname <- if (idx == 1L) sprintf("%s.xlsx", leaf) else sprintf("%s_%03d.xlsx", leaf, idx)
    out <- file.path(base_dir, head(path_parts, -1), fname)
    write_df_excel(x, out, leaf)
    return(invisible(NULL))
  }
  
  if (is.list(x)) {
    nms <- names(x)
    if (is.null(nms)) nms <- rep("", length(x))
    
    for (i in seq_along(x)) {
      nm <- nms[[i]]
      nm_use <- if (nzchar(nm)) nm else sprintf("item_%03d", i)
      nm_use <- safe_name(nm_use, 80)
      walk_nested(x[[i]], base_dir, c(path_parts, nm_use), counters)
    }
  }
  
  invisible(NULL)
}

doi_dir <- file.path("downloads", safe_name(doi, 120))
ensure_dir(doi_dir)

top_names <- names(obj)
if (is.null(top_names)) top_names <- rep("", length(obj))

for (i in seq_along(obj)) {
  top_nm <- top_names[[i]]
  top_use <- if (nzchar(top_nm)) top_nm else sprintf("list_%03d", i)
  top_use <- safe_name(top_use, 80)
  
  top_dir <- file.path(doi_dir, top_use)
  ensure_dir(top_dir)
  
  walk_nested(obj[[i]], base_dir = top_dir)
}

message("Done. Wrote Excel files under: ", normalizePath(doi_dir, winslash = "/", mustWork = FALSE))

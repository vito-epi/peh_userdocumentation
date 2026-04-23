# scripts/zenodo_rds_to_xlsx.R
# Zenodo DOI -> record via REST API -> download .rds -> nested lists -> data.frames -> Excel workbooks

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
  if (is.null(path) || length(path) == 0) return(invisible(FALSE))
  path <- as.character(path[[1]])
  if (is.na(path) || path == "") return(invisible(FALSE))
  dir.create(path, showWarnings = FALSE, recursive = TRUE)
  invisible(TRUE)
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

files <- rec$files
if (is.null(files) || length(files) == 0) stop("Zenodo record has no files: ", doi)

# Pick the RDS file
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
  dl_url <- sprintf("https://zenodo.org/api/records/%s/files/%s/content", rec$id, URLencode(pick_key, reserved = TRUE))
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

# ---- Output folder ----
doi_dir <- file.path("downloads", safe_name(doi, 120))
ensure_dir(doi_dir)


                             


# ---- Excel helpers ----

sheet_safe <- function(x) {
  x <- safe_name(x, max_len = 31)
  x <- gsub("\\[|\\]", "_", x)
  x <- ifelse(is.na(x) | x == "", "Sheet", x)
  substr(x, 1, 31)
}

# ==========================================================
# CASE 0: RDS itself is already a list of data.frames
# (your second DOI structure)
# ==========================================================
if (length(obj) > 0 && all(vapply(obj, is.data.frame, logical(1)))) {
  
  message("RDS is a top-level list of data.frames")
  
  df_names <- names(obj)
  df_names <- ifelse(
    is.na(df_names) | df_names == "",
    sprintf("item_%03d", seq_along(obj)),
    df_names
  )
  
  out_file <- unique_file_path(
    folder   = doi_dir,
    base_name = "data",
    ext      = ".xlsx"
  )
  
  write_workbook_for_df_list(
    df_list     = obj,
    out_file    = out_file,
    sheet_names = df_names
  )
  
  # Skip all further nesting logic
  done <- TRUE
  
} else {
  done <- FALSE
}

make_unique <- function(x) {
  out <- character(length(x))
  seen <- list()
  for (i in seq_along(x)) {
    base <- sheet_safe(x[[i]])
    cand <- base
    k <- 1L
    while (!is.null(seen[[cand]])) {
      k <- k + 1L
      suffix <- paste0("_", k)
      cand <- substr(base, 1, max(1, 31 - nchar(suffix)))
      cand <- paste0(cand, suffix)
    }
    seen[[cand]] <- TRUE
    out[[i]] <- cand
  }
  out
}

write_workbook_for_df_list <- function(df_list, out_file, sheet_names) {
  ensure_dir(dirname(out_file))
  wb <- createWorkbook()
  sheet_names <- make_unique(sheet_names)
  
  for (i in seq_along(df_list)) {
    df <- df_list[[i]]
    if (!is.data.frame(df)) next
    sh <- sheet_names[[i]]
    addWorksheet(wb, sh)                           # [3](https://rdrr.io/cran/openxlsx/man/addWorksheet.html)
    writeDataTable(wb, sh, df, withFilter = TRUE)  # [4](https://joshuasturm.github.io/openxlsx/reference/writeDataTable.html)
    freezePane(wb, sh, firstRow = TRUE)
    if (ncol(df) > 0) setColWidths(wb, sh, cols = 1:ncol(df), widths = "auto")
  }
  
  saveWorkbook(wb, out_file, overwrite = TRUE)      # [2](https://www.rdocumentation.org/packages/openxlsx/versions/4.2.8.1/topics/saveWorkbook)
}

unique_file_path <- function(folder, base_name, ext = ".xlsx") {
  base_name <- safe_name(base_name, max_len = 120)
  if (is.na(base_name) || base_name == "") base_name <- "workbook"
  candidate <- file.path(folder, paste0(base_name, ext))
  if (!file.exists(candidate)) return(candidate)
  for (k in 2:9999) {
    suf <- sprintf("_%03d", k)
    cand <- file.path(folder, paste0(substr(base_name, 1, max(1, 120 - nchar(suf))), suf, ext))
    if (!file.exists(cand)) return(cand)
  }
  file.path(folder, paste0(base_name, "_", as.integer(Sys.time()), ext))
}

walk_nested <- function(x, base_dir, path_parts = character()) {
  if (!is.list(x)) return(invisible(NULL))
  
  nms <- names(x)
  if (is.null(nms)) nms <- rep("", length(x))
  
  is_df <- vapply(x, is.data.frame, logical(1))
  
  # If current list contains any data.frames, write ONE workbook named after this list node
  if (any(is_df)) {
    node_name <- if (length(path_parts) > 0) tail(path_parts, 1) else "root"
    
    df_idx <- which(is_df)
    df_list <- x[df_idx]
    df_names <- nms[df_idx]
    df_names <- ifelse(is.na(df_names) | df_names == "", sprintf("item_%03d", df_idx), df_names)
    
    out_file <- unique_file_path(base_dir, node_name, ext = ".xlsx")
    write_workbook_for_df_list(df_list, out_file, df_names)
  }
  
  # Recurse into non-data.frame children
  for (i in seq_along(x)) {
    if (is_df[[i]]) next
    nm <- nms[[i]]
    nm_use <- if (!is.na(nm) && nzchar(nm)) nm else sprintf("item_%03d", i)
    nm_use <- safe_name(nm_use, max_len = 80)
    walk_nested(x[[i]], base_dir = base_dir, path_parts = c(path_parts, nm_use))
  }
  
  invisible(NULL)
}



# Top-level: create 3 separate workbooks (adults/children/teenagers etc.) directly in doi_dir
if (!done) {
  
  top_names <- names(obj)
  if (is.null(top_names)) top_names <- rep("", length(obj))
  
  for (i in seq_along(obj)) {
    current <- obj[[i]]
    top_nm <- top_names[[i]]
    top_use <- if (!is.na(top_nm) && nzchar(top_nm)) top_nm else sprintf("list_%03d", i)
    top_use <- safe_name(top_use, max_len = 80)
    
    walk_nested(current, base_dir = doi_dir, path_parts = c(top_use))
  }
}



# Generate downloads/index.html so /downloads/ works in browser (needs index.html) [2](https://docs.github.com/en/pages/getting-started-with-github-pages/troubleshooting-404-errors-for-github-pages-sites)
xlsx_files <- list.files("downloads", pattern = "\\.xlsx$", recursive = TRUE, full.names = TRUE)
index_path <- file.path("downloads", "index.html")

lines <- c(
  "<!doctype html><html><head><meta charset='utf-8'><title>Downloads</title></head><body>",
  "<h1>Downloads</h1><ul>",
  vapply(xlsx_files, function(f) {
    rel <- gsub("^downloads/", "", f)
    sprintf("<li><a href='%s'>%s</a></li>", rel, rel)
  }, character(1)),
  "</ul></body></html>"
)
writeLines(lines, index_path)



# ALSO create an index.html inside the DOI folder
xlsx_doi <- list.files(doi_dir, pattern = "\\.xlsx$", full.names = FALSE)
xlsx_doi <- sort(xlsx_doi)

doi_index_path <- file.path(doi_dir, "index.html")

doi_lines <- c(
  "<!doctype html><html><head><meta charset='utf-8'><title>Downloads</title></head><body>",
  sprintf("<h1>Downloads for %s</h1>", doi),
  "<p>Click a file to download it.</p>",
  "<ul>",
  if (length(xlsx_doi) == 0) "<li><em>No .xlsx files found in this folder.</em></li>" else
    vapply(xlsx_doi, function(f) {
      # links are relative to the DOI folder
      sprintf("<li><a href='%s'>%s</a></li>", f, f)
    }, character(1)),
  "</ul>",
  "</body></html>"
)

writeLines(doi_lines, doi_index_path)

message("Done. Wrote Excel workbooks under: ", normalizePath(doi_dir, winslash = "/", mustWork = FALSE))




# scripts/build_downloads_for_doi.R
# Wrapper around the existing working zenodo_rds_to_xlsx.R script

build_downloads_for_doi <- function(doi,
                                    rds_key = "",
                                    out_script = "scripts/zenodo_rds_to_xlsx.R") {
  
  if (is.null(doi) || !nzchar(doi)) stop("Missing DOI")
  
  Sys.setenv(ZENODO_DOI = doi)
  
  if (!is.null(rds_key) && nzchar(rds_key)) {
    Sys.setenv(ZENODO_RDS_KEY = rds_key)
  } else {
    Sys.unsetenv("ZENODO_RDS_KEY")
  }
  
  # IMPORTANT: parent = globalenv() so attached packages (e.g. httr::GET) resolve correctly
  run_env <- new.env(parent = globalenv())
  source(out_script, local = run_env)
  
  invisible(TRUE)
}

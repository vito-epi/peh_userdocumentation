# scripts/build_downloads_for_doi.R
# Wrapper around the existing working zenodo_rds_to_xlsx.R script

build_downloads_for_doi <- function(doi,
                                    rds_key = "",
                                    out_script = "scripts/zenodo_rds_to_xlsx.R") {
  
  if (is.null(doi) || !nzchar(doi)) stop("Missing DOI")
  
  # Set DOI for the existing script (it already reads ZENODO_DOI)
  Sys.setenv(ZENODO_DOI = doi)
  
  # Optional: select a specific .rds file
  if (!is.null(rds_key) && nzchar(rds_key)) {
    Sys.setenv(ZENODO_RDS_KEY = rds_key)
  } else {
    Sys.unsetenv("ZENODO_RDS_KEY")
  }
  
  # Run the existing script in its own environment (prevents variable leakage)
  # IMPORTANT: parent must be baseenv() so base functions exist
  run_env <- new.env(parent = baseenv())
  source(out_script, local = run_env)
  
  invisible(TRUE)
}

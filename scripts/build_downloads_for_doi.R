# scripts/build_downloads_for_doi.R
# Wrapper around the existing working zenodo_rds_to_xlsx.R script

build_downloads_for_doi <- function(doi,
                                    rds_key = "",
                                    out_script = "scripts/zenodo_rds_to_xlsx.R") {
  
  if (is.null(doi) || !nzchar(doi)) stop("Missing DOI")
  
  # Set DOI for the existing script (it already reads ZENODO_DOI)
  Sys.setenv(ZENODO_DOI = doi)
  
  # Optional: if you want to target a specific .rds filename inside the Zenodo record
  if (!is.null(rds_key) && nzchar(rds_key)) {
    Sys.setenv(ZENODO_RDS_KEY = rds_key)
  } else {
    Sys.unsetenv("ZENODO_RDS_KEY")
  }
  
  # Run the existing script in its own environment (prevents variable leakage)
  source(out_script, local = new.env(parent = emptyenv()))
  
  invisible(TRUE)
}

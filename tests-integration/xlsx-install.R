# Installs the CRAN xlsx package and its test dependencies into a separate
# library, leaving the deferred-loading rJava on R_LIBS as the only rJava:
#   Rscript tests-integration/xlsx-install.R <library> <source directory>
args <- commandArgs(TRUE)
lib <- args[1]
dir.create(lib, recursive = TRUE, showWarnings = FALSE)
dir.create(args[2], recursive = TRUE, showWarnings = FALSE)
# Under Git bash, R on Windows does not read the profile setup-r writes.
if (is.null(getOption("repos")) || identical(unname(getOption("repos")["CRAN"]), "@CRAN@"))
  options(repos = c(CRAN = "https://cloud.r-project.org"))
# rJava is already installed, so it is not installed as a dependency.
install.packages(c("xlsxjars", "testthat", "rprojroot", "tibble", "knitr"), lib = lib)
# The source package from CRAN: the P3M Linux repositories serve binaries.
src <- download.packages("xlsx", args[2], repos = "https://cloud.r-project.org", type = "source")[, 2]
install.packages(src, lib = lib, repos = NULL, type = "source")
stopifnot(dir.exists(file.path(lib, "xlsx")), !dir.exists(file.path(lib, "rJava")))

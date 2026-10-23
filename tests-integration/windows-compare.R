# A single subprocess probe. Failures are recorded as experimental outcomes;
# the parent compares outcomes across builds instead of assuming success.
args <- commandArgs(TRUE)
stopifnot(.Platform$OS.type == "windows", length(args) == 2L)
lib <- args[1]
scenario <- args[2]
.libPaths(c(lib, .Library))
home <- Sys.getenv("RJE_JAVA_HOME_TEST")
sysroot <- Sys.getenv("SystemRoot")
minimal <- paste(c(R.home("bin"), file.path(sysroot, "System32"), sysroot), collapse = ";")
Sys.setenv(JAVA_HOME = home, PATH = minimal, NOAWT = "1")
Sys.unsetenv(c("CLASSPATH", "JAVA_TOOL_OPTIONS", "JDK_JAVA_OPTIONS"))
options(java.parameters = "-Djava.awt.headless=true")
if (scenario == "bundled-jri") {
  native <- file.path(lib, "rJava", "jri", "x64")
  if (!dir.exists(native)) native <- dirname(native)
  options(java.parameters = c("-Djava.awt.headless=true", paste0("-Djava.library.path=", native)))
}
stage <- "observe-before-Java"
modules <- function() .C("rjava_compare_modules", PACKAGE = "windows-modules")
result <- tryCatch({
  dyn.load(Sys.getenv("RJE_COMPARE_MODULES"))
  modules()
  package <- find.package("rJava", lib.loc = lib)
  if (scenario == "hosted") {
    stage <- "native-host-startup"
    dyn.load(Sys.getenv("RJE_COMPARE_HOST"))
    paths <- list.files(home, "^jvm[.]dll$", recursive = TRUE, full.names = TRUE)
    path <- paths[grepl("/server/", paths, fixed = TRUE)][1]
    stopifnot(!is.na(path))
    boot <- file.path(package, "java", "boot")
    stopifnot(.C("rjava_test_create_jvm", normalizePath(path, winslash = "/"),
                 paste0("-Djava.class.path=", boot), result = 0L)$result == 0L)
  }
  stage <- "namespace-load"
  loadNamespace("rJava", lib.loc = lib)
  stopifnot(identical(normalizePath(find.package("rJava")), normalizePath(package)))
  stage <- "startup-and-late-native-loads"
  source(Sys.getenv("RJE_COMPARE_WORKLOAD"))
  stopifnot(windows_workload(home))
  if (scenario == "bundled-jri") {
    stage <- "bundled-JRI"
    jar <- system.file("jri", "JRI.jar", package = "rJava")
    stopifnot(file.exists(jar))
    engine <- rJava::.jengine(TRUE)
    stopifnot(!rJava::is.jnull(engine))
  }
  TRUE
}, error = function(e) {
  cat("OBSERVED FAILURE at", stage, ":", conditionMessage(e), "\n")
  FALSE
})
try(modules(), silent = TRUE)
cat("RESULT|", if (result) "PASS" else "FAIL", "|", stage, "\n", sep = "")
quit(status = if (result) 0L else 1L)

# Each scenario must run in a fresh R process against the installed source build.
args <- commandArgs(TRUE)
scenario <- args[1]
home_a <- Sys.getenv("RJE_JAVA_HOME_A")
home_b <- Sys.getenv("RJE_JAVA_HOME_B")
stopifnot(dir.exists(home_a), dir.exists(home_b))
Sys.setenv(JAVA_HOME = file.path(tempdir(), "missing-jdk"))
old_path <- Sys.getenv("PATH")
ns <- loadNamespace("rJava")
state <- function() get(".jvmState", ns)()
stopifnot(identical(state()$state, "not-loaded"), !state()$initialized,
          identical(old_path, Sys.getenv("PATH")))
lib <- function(home) {
  pattern <- if (.Platform$OS.type == "windows") "^jvm[.]dll$" else "^libjvm[.](so|dylib)$"
  paths <- list.files(home, pattern, recursive = TRUE, full.names = TRUE)
  paths <- paths[grepl("/server/", paths, fixed = TRUE)]
  stopifnot(length(paths) >= 1L)
  normalizePath(paths[1], winslash = "/")
}
if (scenario == "retry") {
  failed <- try(rJava::.jinit(), silent = TRUE)
  stopifnot(inherits(failed, "try-error"), state()$state == "not-loaded")
  # A native library with no JNI exports must fail cleanly and permit retry.
  loadNamespace("stats")
  wrong <- getLoadedDLLs()[["stats"]][["path"]]
  failed <- try(get(".jloadJVM", ns)(wrong), silent = TRUE)
  stopifnot(inherits(failed, "try-error"), state()$state == "not-loaded")
} else if (scenario == "unload") {
  get(".jloadJVM", ns)(lib(home_a))
  stopifnot(state()$state == "none", !state()$initialized)
  stopifnot(get(".junloadJVM", ns)(), state()$state == "not-loaded")
  # Calls after unloading must not use stale function pointers.
  stopifnot(state()$state == "not-loaded")
} else stopifnot(scenario == "select")
selected <- if (scenario == "unload") home_a else home_b
Sys.setenv(JAVA_HOME = selected)
rJava::.jinit()
stopifnot(state()$initialized, state()$state == "created")
actual <- rJava::.jcall("java/lang/System", "S", "getProperty", "java.home")
stopifnot(identical(normalizePath(actual), normalizePath(selected)))
# Exercise JNI signatures, references, arrays and exceptions, beyond initialization.
obj <- rJava::.jnew("java/lang/String", "deferred")
stopifnot(rJava::.jcall(obj, "I", "length") == 8L,
          identical(rJava::.jevalArray(rJava::.jarray(1:3)), 1:3))
failed <- try(get(".junloadJVM", ns)(), silent = TRUE)
stopifnot(inherits(failed, "try-error"), state()$state == "created",
          rJava::.jcall(obj, "I", "length") == 8L)
cat("PASS", scenario, rJava::.jcall("java/lang/System", "S", "getProperty", "java.version"), "\n")

# Real overlayfs in a VM. Each mode runs in a fresh process.
scenario <- commandArgs(TRUE)[1]
expect <- Sys.getenv("RJE_OVERLAY_EXPECT")
stopifnot(expect %in% c("legacy", "distro", "current"), Sys.info()[["sysname"]] == "Linux")
kernel <- numeric_version(sub("-.*", "", Sys.info()[["release"]]))
stopifnot(if (expect == "current") kernel >= "6.8" else kernel < "6.8")
a <- Sys.getenv("RJE_JAVA_HOME_A")
b <- Sys.getenv("RJE_JAVA_HOME_B")
Sys.setenv(JAVA_HOME = a, PATH = "/usr/bin:/bin")
ns <- loadNamespace("rJava")
lib <- function(home) get(".find.jvm.library", ns)(home)[1]
state <- function() rJava::.jvmState()$state
mapped <- function() .Call(get("RgetMappedJVM", ns))
reject <- function(path, pattern) {
  error <- tryCatch(rJava::.jloadJVM(path), error = identity)
  stopifnot(inherits(error, "error"), grepl(pattern, conditionMessage(error)), state() == "not-loaded")
  cat("Expected refusal:", conditionMessage(error), "\n")
}
start <- function() {
  rJava::.jinit()
  actual <- rJava::.jcall("java/lang/System", "S", "getProperty", "java.home")
  stopifnot(identical(normalizePath(actual), normalizePath(a)))
}
stopifnot(is.null(mapped()), state() == "not-loaded")
if (scenario == "fresh") {
  start() # New selection works even on an older overlayfs kernel.
} else {
  if (scenario == "hosted") {
    dyn.load(Sys.getenv("RJE_JVMHOST"))
    boot <- file.path(system.file("java", package = "rJava"), "boot")
    stopifnot(.C("rjava_test_create_jvm", lib(a), paste0("-Djava.class.path=", boot), result = 0L)$result == 0L)
  } else dyn.load(lib(a), local = TRUE)
  stopifnot(!is.null(mapped()), mapped()$vms == if (scenario == "hosted") 1L else 0L)
  # Record the actual mapping and overlay inode in CI, not just kernel versions.
  cat(readLines("/proc/self/maps")[grepl("libjvm", readLines("/proc/self/maps"))], sep = "\n")
  system2("stat", c("-Lc", shQuote("overlay device=%d inode=%i"), shQuote(lib(a))))
  reject(lib(b), "already mapped")
  if (scenario == "replaced") {
    # Replacing through the overlay triggers copy-up/whiteout behavior.
    path <- lib(a)
    stopifnot(unlink(path) == 0L, file.copy(lib(b), path))
    reject(path, "already mapped")
  } else {
    if (expect == "legacy") reject(lib(a), "overlayfs before Linux 6.8") else {
      stopifnot(isTRUE(rJava::.jloadJVM(lib(a))))
    }
    if (scenario == "hosted") {
      Sys.setenv(JAVA_HOME = b)
      start() # Attach has no pathname comparison, including on old overlayfs.
      stopifnot(state() == "attached")
    } else if (expect != "legacy") start()
  }
}
cat("PASS overlay", expect, as.character(kernel), scenario, "\n")

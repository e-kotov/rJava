# Runs laterload (A or B) with System32 VC++ DLLs hidden by the workflow,
# then proves Windows actually loaded the selected JDK's bundled runtimes.
source("tests-integration/deferred.R")
stopifnot(windows, scenario == "laterload")
ps <- file.path(sysroot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
modules <- system2(ps, c("-NoProfile", "-Command",
  shQuote(sprintf("(Get-Process -Id %d).Modules | ForEach-Object FileName", Sys.getpid()))), stdout = TRUE)
stopifnot(is.null(attr(modules, "status")))
runtimes <- modules[grepl("[/\\\\](msvcp140|vcruntime140|vcruntime140_1)[.]dll$", modules, ignore.case = TRUE)]
stopifnot(any(tolower(basename(chartr("\\", "/", runtimes))) == "msvcp140.dll"))
selected <- normalizePath(if (variant == "b") home_b else home_a, winslash = "/")
stopifnot(all(startsWith(tolower(normalizePath(runtimes, winslash = "/")), paste0(tolower(selected), "/"))))
cat("PASS bundled MSVC dependencies:", runtimes, sep = "\n  ")

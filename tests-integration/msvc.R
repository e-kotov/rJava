# Verify selected-JDK runtime origins for fresh startup and native-host attachment.
source("tests-integration/deferred.R")
stopifnot(windows, scenario %in% c("laterload", "hosted", "retained"))
ps <- file.path(sysroot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
modules <- system2(ps, c("-NoProfile", "-Command",
  shQuote(sprintf("(Get-Process -Id %d).Modules | ForEach-Object FileName", Sys.getpid()))), stdout = TRUE)
stopifnot(is.null(attr(modules, "status")))
runtimes <- modules[grepl("[/\\\\](msvcp140(_1|_2|_atomic_wait)?|vcruntime140(_1)?)[.]dll$", modules, ignore.case = TRUE)]
names <- tolower(basename(chartr("\\", "/", runtimes)))
stopifnot("msvcp140.dll" %in% names)
selected <- normalizePath(if (variant == "b") home_b else home_a, winslash = "/")
bin <- dirname(dirname(lib(selected)))
for (i in seq_along(runtimes)) {
  bundled <- file.path(bin, names[i])
  expected <- if (file.exists(bundled)) bundled else file.path(sysroot, "System32", names[i])
  stopifnot(identical(tolower(normalizePath(runtimes[i], winslash = "/")),
                      tolower(normalizePath(expected, winslash = "/"))))
}
cat("PASS bundled MSVC dependencies:", runtimes, sep = "\n  ")

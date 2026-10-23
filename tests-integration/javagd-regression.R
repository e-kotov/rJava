# Each invocation is a fresh process with one pinned rJava installation.
a <- commandArgs(TRUE)
.libPaths(c(a[1], a[2], .libPaths()))
cat("JAVA_HOME:", Sys.getenv("JAVA_HOME", "<unset>"), "\n")
cat("rJava:", find.package("rJava"), "\n")
result <- tryCatch({
  if (a[3] == "javagd") library(JavaGD)
  library(rJava)
  .jinit()
  home <- .jcall("java/lang/System", "S", "getProperty", "java.home")
  cat("JAVA_HOME_ACTUAL:", home, "\n")
  if (a[3] == "javagd") {
    # Exercise a real native JavaGD entry point after it loads libjvm.
    cat("JavaGD:", .Call(getNativeSymbolInfo("javaGDversion", "JavaGD")), "\n")
  }
  TRUE
}, error=function(e) {
  cat("ERROR:", conditionMessage(e), "\n")
  FALSE
})
cat("RESULT|", if (result) "PASS" else "FAIL", "\n", sep="")
quit(status=if (result) 0L else 1L)

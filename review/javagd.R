# Rscript javagd.R <rJava lib> <JavaGD lib> <scenario>
a <- commandArgs(TRUE)
.libPaths(c(a[1], a[2], .libPaths()))
cat("JAVA_HOME in R:", Sys.getenv("JAVA_HOME", "<unset>"), "\n")
cat("rJava from:", find.package("rJava"), "\n")
if (a[3] == "javagd") {
  r <- tryCatch({ library(JavaGD); "ok" }, error = function(e) conditionMessage(e))
  cat("LIBRARY(JavaGD):", r, "\n")
  if (r != "ok") { cat("RESULT|FAIL|library\n"); quit(status = 2) }
}
library(rJava)
r <- tryCatch({ .jinit(); "ok" }, error = function(e) conditionMessage(e))
cat(".jinit():", r, "\n")
if (r != "ok") { cat("RESULT|FAIL|jinit\n"); quit(status = 3) }
cat("java.home:", .jcall("java/lang/System", "S", "getProperty", "java.home"), "\n")
if (a[3] == "javagd") cat("JavaGD native:", .Call(getNativeSymbolInfo("javaGDversion", "JavaGD")), "\n")
cat("RESULT|PASS\n")

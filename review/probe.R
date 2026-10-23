# Rscript probe.R <lib|-> <scenario> <mutex.dll> <modules.dll> [jdk-home]
a <- commandArgs(TRUE)
lib <- a[1]; scen <- a[2]; mutex <- a[3]; mods <- a[4]; home <- a[5]
dyn.load(mods)
show <- function(tag) { cat("STAGE", tag, "\n"); invisible(.C("rv_modules")) }
lock <- function() { dyn.load(mutex); show("mutex-loaded"); r <- .C("mutex_probe", x = integer(1)); cat("MUTEX_OK _MSC_VER", r$x, "\n") }
if (scen == "plain") lock()
if (scen == "jdk-msvcp-then-mutex") {
  # control: no rJava; load the JDK's bundled runtimes explicitly first
  bin <- file.path(home, if (dir.exists(file.path(home, "jre"))) "jre/bin" else "bin")
  for (f in c("vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll"))
    if (file.exists(file.path(bin, f))) dyn.load(file.path(bin, f), DLLpath = bin)
  show("jdk-runtimes-loaded"); lock()
}
if (scen %in% c("jinit-then-mutex", "mutex-then-jinit", "missing-workload")) {
  if (scen == "mutex-then-jinit") lock()
  library(rJava, lib.loc = lib)
  .jinit()
  cat("JAVA", .jcall("java/lang/System", "S", "getProperty", "java.version"), "\n")
  show("after-jinit")
  if (scen == "jinit-then-mutex") lock()
  if (scen == "missing-workload") { source(a[6]); windows_workload(home); show("after-workload") }
}
cat("RESULT|PASS|", scen, "\n")

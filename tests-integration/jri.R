# Runs a Java host (JDK A) embedding R through JRI, with JAVA_HOME naming JDK B:
#   Rscript --vanilla tests-integration/jri.R
windows <- .Platform$OS.type == "windows"
home_a <- Sys.getenv("RJE_JAVA_HOME_A")
home_b <- Sys.getenv("RJE_JAVA_HOME_B")
stopifnot(dir.exists(home_a), dir.exists(home_b))
jri <- system.file("jri", package = "rJava")
jar <- file.path(jri, "JRI.jar")
native <- if (windows && dir.exists(file.path(jri, "x64"))) file.path(jri, "x64") else jri
stopifnot(file.exists(jar), length(list.files(native, "jri[.](dll|so|jnilib)$")) == 1L)
classes <- file.path(tempdir(), "classes")
dir.create(classes)
exe <- function(home, tool) file.path(home, "bin", if (windows) paste0(tool, ".exe") else tool)
source_file <- file.path(getwd(), "tests-integration", "JriAttach.java")
stopifnot(system2(exe(home_a, "javac"), c("-cp", shQuote(jar), "-d", shQuote(classes), shQuote(source_file))) == 0L)
# The embedded R needs its own libraries, but no Java directory, on the search path.
sysroot <- Sys.getenv("SystemRoot", "C:\\Windows")
Sys.setenv(
  JAVA_HOME = home_b,
  R_HOME = R.home(),
  R_LIBS = paste(.libPaths(), collapse = .Platform$path.sep),
  PATH = if (windows) paste(normalizePath(c(R.home("bin"), file.path(sysroot, "System32"), sysroot),
                                           winslash = "\\"), collapse = ";") else "/usr/bin:/bin")
if (Sys.info()[["sysname"]] == "Linux") Sys.setenv(LD_LIBRARY_PATH = file.path(R.home(), "lib"))
# A Java host provides rJava's class loader on its class path: JDK 9+ does not
# permit rJava to append it to a running application class loader.
boot <- file.path(system.file("java", package = "rJava"), "boot")
status <- system2(exe(home_a, "java"), c(paste0("-Djava.library.path=", shQuote(native)),
  "-cp", shQuote(paste(jar, boot, classes, sep = .Platform$path.sep)), "JriAttach"))
stopifnot(status == 0L)

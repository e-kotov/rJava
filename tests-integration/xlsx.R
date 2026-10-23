# A CRAN package that starts Java when its namespace loads: xlsx's .onLoad()
# calls rJava::.jpackage(), which runs .jinit(). Run in a fresh process:
#   Rscript --vanilla tests-integration/xlsx.R
# RJE_RJAVA_LIB names the library with the deferred-loading rJava build.
home_a <- Sys.getenv("RJE_JAVA_HOME_A")
home_b <- Sys.getenv("RJE_JAVA_HOME_B")
stopifnot(dir.exists(home_a), dir.exists(home_b))
# A binary rJava installed as a dependency would make this test meaningless.
rjava_lib <- normalizePath(Sys.getenv("RJE_RJAVA_LIB"), winslash = "/")
copies <- .libPaths()[file.exists(file.path(.libPaths(), "rJava", "DESCRIPTION"))]
cat("rJava installed in:", copies, sep = "\n  ")
if (!length(copies) || !identical(normalizePath(copies[1], winslash = "/"), rjava_lib))
  stop("the first rJava on the library path is not the one in ", rjava_lib)

windows <- .Platform$OS.type == "windows"
Sys.setenv(PATH = if (windows) paste(R.home("bin"), file.path(Sys.getenv("SystemRoot"), "System32"), sep = ";") else "/usr/bin:/bin")
ns <- loadNamespace("rJava")
state <- function() get(".jvmState", ns)()
stopifnot(identical(state()$state, "not-loaded"), exists("RgetMappedJVM", ns))
# JDK B, so that the build JDK (A in the current set) cannot be picked up by accident.
Sys.setenv(JAVA_HOME = home_b)
invisible(loadNamespace("xlsx"))
stopifnot(state()$initialized)
actual <- normalizePath(rJava::.jcall("java/lang/System", "S", "getProperty", "java.home"), winslash = "/")
expected <- normalizePath(home_b, winslash = "/")
if (!identical(actual, expected) && !identical(dirname(actual), expected))
  stop("java.home is ", actual, ", expected ", expected)
cat("xlsx started", rJava::.jcall("java/lang/System", "S", "getProperty", "java.version"), "from", actual, "\n")

# Java was selected when xlsx loaded: another runtime cannot be selected later.
other <- get(".find.jvm.library", ns)(home_a)[1]
result <- try(rJava::.jloadJVM(other), silent = TRUE)
stopifnot(inherits(result, "try-error"))
cat("rejected:", substr(gsub("\\s+", " ", result), 1L, 240L), "\n")

file <- tempfile(fileext = ".xlsx")
data <- data.frame(id = 1:150, value = iris$Sepal.Length, species = as.character(iris$Species))
xlsx::write.xlsx(data, file, row.names = FALSE)
back <- xlsx::read.xlsx(file, 1, stringsAsFactors = FALSE)
stopifnot(identical(dim(back), dim(data)), all.equal(back$value, data$value),
          identical(back$species, data$species))
cat("xlsx round trip:", nrow(back), "rows\n")

# Each scenario must run in a fresh R process against the installed source build:
#   Rscript --vanilla tests-integration/deferred.R <scenario> [variant]
# RJE_JAVA_HOME_A and RJE_JAVA_HOME_B must name two different Java homes.
args <- commandArgs(TRUE)
scenario <- args[1]
variant <- if (length(args) > 1L) args[2] else ""
windows <- .Platform$OS.type == "windows"
home_a <- Sys.getenv("RJE_JAVA_HOME_A")
home_b <- Sys.getenv("RJE_JAVA_HOME_B")
stopifnot(dir.exists(home_a), dir.exists(home_b))
log <- function(...) cat(scenario, variant, ":", ..., "\n")

# Runner tool setup must not mask missing discovery or dependency handling:
# no Java directory is on PATH unless a scenario adds one.
sysroot <- Sys.getenv("SystemRoot", "C:\\Windows")
minimal_path <- if (windows) {
  paste(normalizePath(c(R.home("bin"), file.path(sysroot, "System32"), sysroot,
                        file.path(sysroot, "System32", "Wbem")), winslash = "\\"), collapse = ";")
} else "/usr/bin:/bin"
Sys.setenv(PATH = minimal_path, JAVA_HOME = file.path(tempdir(), "missing-jdk"))
Sys.unsetenv(c("CLASSPATH", "LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH", "JAVA_TOOL_OPTIONS", "JDK_JAVA_OPTIONS"))
options(java.parameters = "-Djava.awt.headless=true")
ns <- loadNamespace("rJava")
internal <- function(name) get(name, ns)
state <- function() internal(".jvmState")()
stopifnot(identical(state()$state, "not-loaded"), !state()$initialized,
          identical(minimal_path, Sys.getenv("PATH")))

lib <- function(home) {
  paths <- internal(".find.jvm.library")(home)
  stopifnot(length(paths) >= 1L, grepl("/server/", paths[1], fixed = TRUE))
  normalizePath(paths[1], winslash = "/")
}
relative <- function(home) substring(internal(".find.jvm.library")(home)[1], nchar(home) + 2L)
same_home <- function(actual, expected) {
  # JDK 8 reports its jre subdirectory as java.home.
  actual <- normalizePath(actual, winslash = "/")
  expected <- normalizePath(expected, winslash = "/")
  identical(actual, expected) || identical(dirname(actual), expected)
}
fails <- function(expr, pattern = NULL) {
  path <- Sys.getenv("PATH")
  result <- suppressWarnings(try(expr, silent = TRUE))
  stopifnot(inherits(result, "try-error"), state()$state == "not-loaded",
            identical(path, Sys.getenv("PATH")))
  if (!is.null(pattern) && !grepl(pattern, result))
    stop("unexpected error: ", result)
  log("rejected:", substr(gsub("\\s+", " ", result), 1L, 240L))
}
# Map a JVM library as other native code in the process would, outside rJava.
preload <- function(path, local = TRUE) {
  old <- Sys.getenv("PATH")
  # JDK 8 jvm.dll needs the C runtime from its bin directory.
  if (windows) Sys.setenv(PATH = paste(normalizePath(dirname(dirname(path)), winslash = "\\"), old, sep = ";"))
  dyn.load(path, local = local, now = TRUE)
  Sys.setenv(PATH = old)
}
# A directory name with spaces and non-ASCII characters when the locale allows it.
odd_dir <- function() {
  name <- if (isTRUE(l10n_info()[["UTF-8"]])) "rJava t\u00ebst \u00fc \u65e5\u672c" else "rJava test dir"
  dir <- file.path(if (windows) "C:/rjava-paths" else tempdir(), name)
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  stopifnot(dir.exists(dir))
  dir
}
# A second name for a Java home: a junction on Windows, a symbolic link elsewhere.
link_home <- function(home, dir = odd_dir(), name = "jdk link") {
  link <- file.path(dir, name)
  unlink(link)
  ok <- if (windows) Sys.junction(normalizePath(home), link) else file.symlink(normalizePath(home), link)
  stopifnot(isTRUE(ok), dir.exists(link))
  link
}
start <- function(expected) {
  rJava::.jinit()
  stopifnot(state()$initialized, state()$state %in% c("created", "attached"))
  actual <- rJava::.jcall("java/lang/System", "S", "getProperty", "java.home")
  if (!same_home(actual, expected)) stop("java.home is ", actual, ", expected ", expected)
  # Exercise JNI signatures, references, arrays and exceptions, beyond initialization.
  obj <- rJava::.jnew("java/lang/String", "deferred")
  stopifnot(rJava::.jcall(obj, "I", "length") == 8L,
            identical(rJava::.jevalArray(rJava::.jarray(1:3)), 1:3),
            identical(rJava::.jcall("java/lang/Long", "J", "parseLong", "-4294967297"), -4294967297),
            identical(rJava::.jcall("java/lang/Math", "D", "scalb", 1.5, 2L), 6))
  thrown <- try(rJava::.jcall("java/lang/Integer", "I", "parseInt", "x"), silent = TRUE)
  stopifnot(inherits(thrown, "try-error"), grepl("NumberFormatException", thrown))
  failed <- try(internal(".junloadJVM")(), silent = TRUE)
  stopifnot(inherits(failed, "try-error"), state()$initialized)
  version <- rJava::.jcall("java/lang/System", "S", "getProperty", "java.version")
  log("started", version, "at", actual)
  invisible(actual)
}
# Native libraries the JVM loads after startup, as real workloads would.
later_loads <- function() {
  J <- function(...) rJava::.jcall(...)
  deflater <- rJava::.jnew("java/util/zip/Deflater")
  J(deflater, "V", "setInput", rJava::.jarray(as.raw(1:100)))
  J(deflater, "V", "finish")
  stopifnot(J(deflater, "I", "deflate", rJava::.jarray(raw(200))) > 0L)
  address <- J("java/net/InetAddress", "Ljava/net/InetAddress;", "getByName", "127.0.0.1")
  socket <- rJava::.jnew("java/net/ServerSocket", 0L, 1L, address)
  stopifnot(J(socket, "I", "getLocalPort") > 0L)
  J(socket, "V", "close")
  digest <- J("java/security/MessageDigest", "Ljava/security/MessageDigest;", "getInstance", "SHA-256")
  stopifnot(length(J(digest, "[B", "digest", rJava::.jarray(as.raw(1:3)))) == 32L)
  bean <- J("java/lang/management/ManagementFactory", "Ljava/lang/management/RuntimeMXBean;", "getRuntimeMXBean")
  stopifnot(J(bean, "J", "getUptime") >= 0)
  if (windows) {
    store <- J("java/security/KeyStore", "Ljava/security/KeyStore;", "getInstance", "Windows-MY")
    J(store, "V", "load", rJava::.jnull("java/security/KeyStore$LoadStoreParameter"))
  }
  image <- rJava::.jnew("java/awt/image/BufferedImage", 40L, 20L, 1L)
  graphics <- J(image, "Ljava/awt/Graphics2D;", "createGraphics")
  J(graphics, "V", "drawString", "rJava", 2L, 15L)
  out <- rJava::.jnew("java/io/ByteArrayOutputStream")
  stopifnot(J("javax/imageio/ImageIO", "Z", "write", rJava::.jcast(image, "java/awt/image/RenderedImage"),
              "png", rJava::.jcast(out, "java/io/OutputStream")), J(out, "I", "size") > 0L)
  log("later native loads passed")
  if (windows) {
    ps <- file.path(sysroot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
    modules <- system2(ps, c("-NoProfile", "-Command",
      shQuote(sprintf("(Get-Process -Id %d).Modules | ForEach-Object FileName", Sys.getpid()))), stdout = TRUE)
    keep <- grepl("(java|jdk|jre|zulu|corretto|temurin|vcruntime|msvc|ucrtbase)", modules, ignore.case = TRUE)
    cat("Loaded modules:", modules[keep], sep = "\n  ")
  }
}

switch(scenario,
  select = {
    Sys.setenv(JAVA_HOME = home_b)
    start(home_b)
    stopifnot(identical(minimal_path, Sys.getenv("PATH")))
  },
  retry = {
    empty <- file.path(tempdir(), "home without jvm")
    dir.create(empty)
    Sys.setenv(JAVA_HOME = empty)
    fails(rJava::.jinit(), "Cannot find JVM library")
    fails(internal(".jloadJVM")(file.path(empty, "server", basename(lib(home_a)))))
    # A native library with no JNI exports must fail cleanly and permit retry.
    loadNamespace("stats")
    fails(internal(".jloadJVM")(getLoadedDLLs()[["stats"]][["path"]]), "entry points")
    Sys.setenv(JAVA_HOME = home_b)
    start(home_b)
  },
  badinput = {
    load <- internal(".jloadJVM")
    fails(load(""))
    fails(load(c(lib(home_a), lib(home_b))), "Invalid path")
    fails(load(home_a))
    fails(load(strrep("a", 40000L)))
    # A relative path that only exceeds the Windows path limit once completed.
    fails(load(paste0(strrep("b", 32700L), "/jvm.dll")))
    fails(load(file.path(tempdir(), strrep("c", 300L), "server", basename(lib(home_a)))))
    Sys.setenv(JAVA_HOME = home_b)
    start(home_b)
  },
  unload = {
    internal(".jloadJVM")(lib(home_a))
    stopifnot(state()$state == "none", !state()$initialized)
    failed <- try(internal(".junloadJVM")(), silent = TRUE)
    stopifnot(inherits(failed, "try-error"), state()$state == "none")
    failed <- try(internal(".jloadJVM")(lib(home_b)), silent = TRUE)
    stopifnot(inherits(failed, "try-error"), state()$state == "none")
    Sys.setenv(JAVA_HOME = home_a)
    start(home_a)
  },
  preloaded = {
    # A JVM library mapped outside this loader rejects a different runtime and
    # permits the same one, without starting a VM. With global symbols, its
    # JNI exports must not interpose on rJava's own loader wrappers.
    stopifnot(variant %in% c("", "global"))
    preload(lib(home_a), local = variant != "global")
    mapped <- .Call(internal("RgetMappedJVM"))
    stopifnot(!is.null(mapped), identical(mapped$vms, 0L))
    Sys.setenv(JAVA_HOME = home_b)
    fails(rJava::.jinit(), "already mapped")
    fails(internal(".jloadJVM")(lib(home_b)), "already mapped")
    Sys.setenv(JAVA_HOME = home_a)
    start(home_a)
  },
  alias = {
    # The mapped library must be recognized by file identity, not by name.
    real <- lib(home_a)
    path <- switch(variant,
      link = file.path(link_home(home_a), relative(home_a)),
      short = {
        stopifnot(windows)
        long <- file.path(link_home(home_a, name = "jdk long directory name"), relative(home_a))
        short <- utils::shortPathName(long)
        if (identical(tolower(gsub("\\\\", "/", short)), tolower(long))) stop("no 8.3 name was generated for ", long)
        short
      },
      spelling = if (windows) {
        chartr("/", "\\", toupper(file.path(dirname(dirname(real)), ".", "server", "..", "server", basename(real))))
      } else file.path(dirname(dirname(real)), ".", "server", "..", "server//", basename(real)),
      stop("unknown alias variant"))
    log("alias", path, "of", real)
    preload(real)
    internal(".jloadJVM")(path)
    stopifnot(state()$state == "none")
    start(home_a)
  },
  nonascii = {
    # No preload: the loader itself must open a path with spaces and non-ASCII names.
    Sys.setenv(JAVA_HOME = link_home(home_b))
    start(home_b)
  },
  fallback = {
    # An invalid explicit home is ignored with a warning, as before deferred
    # loading, and discovery falls back. Expected homes are computed outside rJava.
    # Windows: the CI job registers RJE_FALLBACK_HOME under HKCU\Software\JavaSoft.
    # macOS: /usr/libexec/java_home if it finds a runtime. Otherwise: java on PATH.
    expected <- Sys.getenv("RJE_FALLBACK_HOME")
    java_home <- if (file.exists("/usr/libexec/java_home"))
      suppressWarnings(system2("/usr/libexec/java_home", stdout = TRUE, stderr = FALSE))
    if (length(java_home) == 1L && is.null(attr(java_home, "status")) && dir.exists(java_home)) {
      expected <- java_home
    } else if (!windows) Sys.setenv(PATH = paste(file.path(expected, "bin"), minimal_path, sep = ":"))
    stopifnot(dir.exists(expected))
    log("expecting fallback to", expected)
    warned <- FALSE
    withCallingHandlers(rJava::.jinit(), warning = function(w) {
      if (grepl("INVALID", conditionMessage(w))) { warned <<- TRUE; invokeRestart("muffleWarning") }
    })
    stopifnot(warned)
    start(expected)
  },
  laterload = {
    Sys.setenv(JAVA_HOME = home_a)
    start(home_a)
    later_loads()
    stopifnot(identical(minimal_path, Sys.getenv("PATH")))
  },
  hosted = {
    # Native code in this process created a JVM before rJava was used. rJava
    # must attach to it, although JAVA_HOME names another runtime. A host
    # provides rJava's class loader on its class path (JDK 9+ forbids adding it).
    helper <- Sys.getenv("RJE_JVMHOST")
    stopifnot(file.exists(helper))
    dyn.load(helper)
    boot <- file.path(system.file("java", package = "rJava"), "boot")
    old <- Sys.getenv("PATH")
    if (windows) Sys.setenv(PATH = paste(normalizePath(dirname(dirname(lib(home_a))), winslash = "\\"), old, sep = ";"))
    created <- .C("rjava_test_create_jvm", lib(home_a), paste0("-Djava.class.path=", boot), result = 0L)$result
    Sys.setenv(PATH = old)
    stopifnot(created == 0L)
    mapped <- .Call(internal("RgetMappedJVM"))
    stopifnot(!is.null(mapped), identical(mapped$vms, 1L), state()$state == "not-loaded")
    Sys.setenv(JAVA_HOME = home_b)
    start(home_a)
    stopifnot(state()$state == "attached")
  },
  jengine = {
    # R hosts the JVM, then JRI is loaded into it as a later native library.
    jri <- system.file("jri", package = "rJava")
    if (windows && dir.exists(file.path(jri, "x64"))) jri <- file.path(jri, "x64")
    options(java.parameters = c("-Djava.awt.headless=true", paste0("-Djava.library.path=", jri)))
    Sys.setenv(JAVA_HOME = home_a)
    start(home_a)
    engine <- rJava::.jengine(TRUE)
    stopifnot(!rJava::is.jnull(engine))
    stopifnot(identical(rJava::.jcall(engine, "Z", "isStandAlone"), FALSE))
    log("JRI engine started inside R")
  },
  stop("unknown scenario: ", scenario))
cat("PASS", scenario, variant, "\n")

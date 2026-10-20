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
mapped_jvm <- function() .Call(internal("RgetMappedJVM"))
# rJava's own JNI wrappers (exported by rJava.dll) must not count as a JVM.
stopifnot(identical(state()$state, "not-loaded"), !state()$initialized,
          identical(minimal_path, Sys.getenv("PATH")), is.null(mapped_jvm()))

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
preload <- function(path, local = TRUE, bin = dirname(dirname(path))) {
  old <- Sys.getenv("PATH")
  # JDK 8 jvm.dll needs the C runtime from its bin directory.
  if (windows) Sys.setenv(PATH = paste(normalizePath(bin, winslash = "\\"), old, sep = ";"))
  dyn.load(path, local = local, now = TRUE)
  Sys.setenv(PATH = old)
}
# Another name for the JVM library of a home, with a basename no JVM uses:
# a hard link in its own directory, from which the JVM still finds its home.
# A mapped DLL cannot be deleted, so Windows removes earlier links first.
alias_lib <- function(home) {
  real <- lib(home)
  unlink(Sys.glob(file.path(dirname(real), "rjava-alias-*")))
  alias <- file.path(dirname(real), paste0("rjava-alias-", Sys.getpid(), ".", tools::file_ext(real)))
  stopifnot(file.link(real, alias))
  reg.finalizer(globalenv(), function(e) unlink(alias), onexit = TRUE)
  alias
}
# The library must be recognized by its exports, not by its name.
expect_mapped <- function(path, vms) {
  mapped <- mapped_jvm()
  if (is.null(mapped)) stop("no mapped JVM library was found; expected ", path)
  log("mapped", mapped$path, "with", mapped$vms, "VMs")
  stopifnot(identical(mapped$vms, vms))
  if (!is.null(path) && !identical(basename(mapped$path), basename(path)))
    stop("mapped library is ", mapped$path, ", expected ", path)
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
    # The internal attach used by .jinit() selects only a created VM.
    attach <- function() .Call(internal("RattachJVM"))
    fails(attach(), "No JVM library is mapped")
    preload(lib(home_a), local = variant != "global")
    mapped <- .Call(internal("RgetMappedJVM"))
    stopifnot(!is.null(mapped), identical(mapped$vms, 0L))
    fails(attach(), "created no VM")
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
  renamed = {
    # A JVM library mapped under a name no JVM uses, by a copy, hard link or
    # symbolic link, rejects another runtime; the same file is still accepted.
    if (variant == "copy") {
      # A copy of B is another file than B's own library, and than A's.
      copy <- file.path(odd_dir(), paste0("renamed runtime.", tools::file_ext(lib(home_b))))
      stopifnot(file.copy(lib(home_b), copy, overwrite = TRUE))
      preload(copy, bin = dirname(dirname(lib(home_b))))
      expect_mapped(copy, 0L)
      Sys.setenv(JAVA_HOME = home_a)
      fails(rJava::.jinit(), "already mapped")
      fails(internal(".jloadJVM")(lib(home_b)), "already mapped")
      expect_mapped(copy, 0L)
    } else {
      path <- switch(variant,
        hardlink = alias_lib(home_a),
        symlink = {
          stopifnot(!windows)
          link <- file.path(odd_dir(), paste0("renamed link.", tools::file_ext(lib(home_a))))
          unlink(link)
          stopifnot(file.symlink(lib(home_a), link))
          link
        },
        stop("unknown renamed variant"))
      log("renamed", path, "of", lib(home_a))
      preload(path, bin = dirname(dirname(lib(home_a))))
      # dyld may record a symbolic link by its target, so only a hard link
      # is certain to be mapped under the unusual name.
      expect_mapped(if (variant == "hardlink") path, 0L)
      Sys.setenv(JAVA_HOME = home_b)
      fails(rJava::.jinit(), "already mapped")
      fails(internal(".jloadJVM")(lib(home_b)), "already mapped")
      Sys.setenv(JAVA_HOME = home_a)
      if (windows) {
        # The JDK's DLLs import jvm.dll by name, which this module lacks.
        fails(rJava::.jinit(), "under another name")
      } else {
        start(home_a)
        expect_mapped(if (variant == "hardlink") path, 1L)
      }
    }
  },
  replaced = {
    # The file the mapped JVM library was loaded from is deleted, or replaced
    # by B's library under the same name. Identity is that of the mapped file,
    # not of the file now at its name: B must be rejected, A still accepted.
    stopifnot(variant %in% c("deleted", "replaced"))
    if (windows) {
      # A mapped DLL cannot be deleted, but may be renamed. JDK DLLs import
      # jvm.dll by name, so replace jvm.dll in a copy of A's home.
      copy <- file.path("C:/rjava-paths", paste0("replaced-", Sys.getpid()))
      dir.create(copy, recursive = TRUE)
      stopifnot(file.copy(normalizePath(home_a), copy, recursive = TRUE))
      home <- file.path(copy, basename(normalizePath(home_a)))
      path <- file.path(home, relative(home_a))
      preload(path)
      expect_mapped(path, 0L)
      stopifnot(unlink(path) != 0L || file.exists(path))
      log("Windows refused deleting the mapped", path)
      if (variant == "deleted") {
        fails(internal(".jloadJVM")(lib(home_b)), "already mapped")
        internal(".jloadJVM")(path)
        stopifnot(state()$state == "none")
        start(home)
      } else {
        moved <- file.path(dirname(path), "jvm-mapped.dll")
        stopifnot(file.rename(path, moved), file.link(lib(home_b), path))
        log("renamed the mapped DLL to", moved, "and linked B's in its place")
        expect_mapped(NULL, 0L)
        fails(internal(".jloadJVM")(lib(home_b)), "already mapped")
        fails(internal(".jloadJVM")(path), "already mapped")
        Sys.setenv(JAVA_HOME = home_b)
        fails(rJava::.jinit(), "already mapped")
        internal(".jloadJVM")(moved)
        stopifnot(state()$state == "none")
        start(home)
        expect_mapped(NULL, 1L)
      }
    } else {
      path <- alias_lib(home_a)
      preload(path)
      expect_mapped(path, 0L)
      stopifnot(unlink(path) == 0L, !file.exists(path))
      if (variant == "replaced") {
        # A hard link, so the old check (the file now at the mapped name is B's
        # library) accepted B and kept A's handle.
        stopifnot(file.link(lib(home_b), path))
        log("replaced", path, "by a hard link of", lib(home_b))
      }
      fails(internal(".jloadJVM")(lib(home_b)), "already mapped")
      fails(internal(".jloadJVM")(path), "already mapped")
      Sys.setenv(JAVA_HOME = home_b)
      fails(rJava::.jinit(), "already mapped")
      # A's library is the mapped file, whatever is now at the mapped name.
      internal(".jloadJVM")(lib(home_a))
      stopifnot(state()$state == "none")
      expect_mapped(path, 0L)
      # The JVM finds its home from its own file name, which no longer exists
      # if deleted.
      if (variant == "replaced") {
        start(home_a)
        expect_mapped(path, 1L)
      }
    }
  },
  decoy = {
    # The Java launcher library (jli) has JNI exports on macOS that forward to
    # libjvm, but is no JVM: it must neither be reported nor block selection.
    jli <- list.files(home_a, "^(lib)?jli[.](so|dylib|dll)$", recursive = TRUE, full.names = TRUE)
    stopifnot(length(jli) >= 1L)
    log("decoy", jli[1])
    preload(jli[1], bin = dirname(jli[1]))
    stopifnot(is.null(mapped_jvm()))
    Sys.setenv(JAVA_HOME = home_b)
    start(home_b)
  },
  byname = {
    # musl resolves the libjvm.so dependency of the JDK's libraries through
    # LD_LIBRARY_PATH as set at process start, which the job points at A's.
    # Selecting B is refused before a VM exists, so no second JVM library is
    # mapped; musl never unmaps B's, which then blocks selecting A.
    stopifnot(Sys.info()[["sysname"]] == "Linux")
    Sys.setenv(JAVA_HOME = home_b)
    fails(rJava::.jinit(), "libjvm.so by name")
    maps <- grep("/libjvm[.]so$", readLines("/proc/self/maps"), value = TRUE)
    maps <- unique(sub("^\\S+\\s+\\S+\\s+\\S+\\s+\\S+\\s+\\S+\\s+", "", maps))
    log("mapped JVM files:", maps)
    stopifnot(length(maps) <= 1L, !lib(home_a) %in% maps)
    if (length(maps)) fails(internal(".jloadJVM")(lib(home_a)), "already mapped")
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
  retained = {
    stopifnot(windows)
    bin <- dirname(dirname(lib(home_a)))
    # Keep the fixture coherent before rJava runs: a plain dyn.load(msvcp)
    # otherwise pulls its VCRUNTIME imports from System32.
    dependencies <- file.path(bin, c("vcruntime140.dll", "vcruntime140_1.dll"))
    dependencies <- dependencies[file.exists(dependencies)]
    for (dependency in dependencies) dyn.load(dependency)
    dll <- file.path(bin, "msvcp140.dll")
    dyn.load(dll)
    dyn.load(Sys.getenv("RJE_JVMHOST"))
    stopifnot(.C("rjava_test_module_loaded", "msvcp140.dll", result = 0L)$result == 1L)
    rJava::.jloadJVM(lib(home_a))
    dyn.unload(dll)
    for (dependency in rev(dependencies)) dyn.unload(dependency)
    stopifnot(.C("rjava_test_module_loaded", "msvcp140.dll", result = 0L)$result == 1L)
    start(home_a)
    later_loads()
  },
  laterload = {
    home <- if (variant == "b") home_b else home_a
    Sys.setenv(JAVA_HOME = home)
    start(home)
    later_loads()
    stopifnot(identical(minimal_path, Sys.getenv("PATH")))
  },
  hosted = {
    # Native code in this process created a JVM before rJava was used. rJava
    # must attach to it, although JAVA_HOME names another runtime. A host
    # provides rJava's class loader on its class path (JDK 9+ forbids adding it).
    # Variant explicit: .jloadJVM() selects A's own file before .jinit().
    # Variant renamed: the host loads the runtime under a name no JVM uses.
    # Not on Windows, where the JDK's DLLs then cannot import jvm.dll by name.
    # Variant replaced: B's library then replaces that name (on Windows, the
    # jvm.dll of a copy of A's home, renamed as in replaced). .jinit() attaches
    # to the created VM, but .jloadJVM() rejects that name and B: a path
    # selects only the file mapped, also when a VM was created.
    if (variant == "laterload-b") {
      swap <- home_a; home_a <- home_b; home_b <- swap
      variant <- "laterload"
    }
    stopifnot(variant %in% c("", "explicit", "renamed", "replaced", "laterload"), !(windows && variant == "renamed"))
    helper <- Sys.getenv("RJE_JVMHOST")
    stopifnot(file.exists(helper))
    dyn.load(helper)
    boot <- file.path(system.file("java", package = "rJava"), "boot")
    home <- home_a
    if (windows && variant == "replaced") {
      copy <- file.path("C:/rjava-paths", paste0("hosted-", Sys.getpid()))
      dir.create(copy, recursive = TRUE)
      stopifnot(file.copy(normalizePath(home_a), copy, recursive = TRUE))
      home <- file.path(copy, basename(normalizePath(home_a)))
      path <- file.path(home, relative(home_a))
    } else path <- if (variant %in% c("renamed", "replaced")) alias_lib(home_a) else lib(home_a)
    old <- Sys.getenv("PATH")
    if (windows) Sys.setenv(PATH = paste(normalizePath(dirname(dirname(path)), winslash = "\\"), old, sep = ";"))
    created <- .C("rjava_test_create_jvm", path, paste0("-Djava.class.path=", boot), result = 0L)$result
    Sys.setenv(PATH = old)
    stopifnot(created == 0L)
    expect_mapped(path, 1L)
    # The name djni_mapped() reports, which .jinit() once passed to .jloadJVM().
    recorded <- mapped_jvm()$path
    if (variant == "replaced") {
      if (windows) {
        moved <- file.path(dirname(path), "jvm-mapped.dll")
        stopifnot(file.rename(path, moved), file.link(lib(home_b), path))
      } else stopifnot(unlink(path) == 0L, file.link(lib(home_b), path))
      log("replaced", path, "by a hard link of", lib(home_b))
      expect_mapped(if (!windows) path, 1L)
    }
    stopifnot(state()$state == "not-loaded")
    Sys.setenv(JAVA_HOME = home_b)
    fails(rJava::.jloadJVM(lib(home_b)), "already mapped")
    if (variant == "replaced") {
      fails(rJava::.jloadJVM(recorded), "already mapped")
      fails(rJava::.jloadJVM(path), "already mapped")
    }
    if (variant == "explicit") {
      stopifnot(isTRUE(rJava::.jloadJVM(lib(home_a))), state()$state == "detached")
    }
    start(home)
    stopifnot(state()$state == "attached")
    if (variant == "laterload") later_loads()
    stopifnot(identical(minimal_path, Sys.getenv("PATH")))
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

.msg <- message

# Extract detection logic to a helper function
.find.java.runtime <- function() {
    # Check options and env vars first
    javahome <- if (!is.null(getOption("java.home"))) {
        getOption("java.home")
    } else {
        Sys.getenv("JAVA_HOME")
    }

    if (nzchar(javahome) && !dir.exists(javahome)) {
        warning("Java home setting is INVALID, it will be ignored.")
        javahome <- ""
    }

    # If not found, try Registry
    if (!nzchar(javahome)) {
        find.java <- function() {
            for (root in c("HLM", "HCU")) {
                for (key in c(
                    "Software\\JavaSoft\\JRE",
                    "Software\\JavaSoft\\JDK",
                    "Software\\JavaSoft\\Java Runtime Environment",
                    "Software\\JavaSoft\\Java Development Kit"
                )) {
                    hive <- try(
                        utils::readRegistry(key, root, 2),
                        silent = TRUE
                    )
                    if (!inherits(hive, "try-error")) return(hive)
                }
            }
            hive
        }
        hive <- find.java()
        if (!inherits(hive, "try-error") && length(hive$CurrentVersion)) {
            this <- hive[[hive$CurrentVersion]]
            javahome <- this$JavaHome
        }
    }
    return(javahome)
}

.onLoad <- function(libname, pkgname) {
    # Attempt to find Java to set up PATH if possible, but do NOT fail if missing
    # This preserves 'old' behavior if Java is present, but allows 'new' behavior if not.
    javahome <- .find.java.runtime()

    if (!is.null(javahome) && nzchar(javahome)) {
        OPATH <- Sys.getenv("PATH")
        # Add bin/server etc to path (logic copied from original)
        paths <- character()
        paths <- c(
            paths,
            file.path(javahome, "bin", "client"),
            file.path(javahome, "bin", "server"),
            file.path(javahome, "bin"),
            file.path(javahome, "jre", "bin", "server"),
            file.path(javahome, "jre", "bin", "client")
        )

        cpc <- strsplit(OPATH, ";", fixed = TRUE)[[1]]
        curPath <- OPATH
        for (path in unique(paths)) {
            if (!path %in% cpc && file.exists(path)) {
                curPath <- paste(path, curPath, sep = ";")
            }
        }

        if (curPath != OPATH) Sys.setenv(PATH = curPath)
    }

    # Load rJava.dll (now without jvm.dll dependency)
    library.dynam("rJava", pkgname, libname)

    # Initialize internal C variables
    .jfirst(libname, pkgname)
}

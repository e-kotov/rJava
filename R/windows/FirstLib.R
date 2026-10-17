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
    library.dynam("rJava", pkgname, libname)
    .jfirst(libname, pkgname)
}

# rJava compiles against its own src/jni.h, not the JDK headers. Check that its
# types and function tables have the layout of each JDK's jni.h:
#   Rscript --vanilla tests-integration/jni-abi.R <java home> [<java home> ...]
homes <- commandArgs(TRUE)
stopifnot(length(homes) >= 1L, all(dir.exists(homes)))
windows <- .Platform$OS.type == "windows"
quote <- function(x) shQuote(x, type = if (windows) "cmd" else "sh")
header <- readLines(file.path("src", "jni.h"))
members <- function(struct) {
  start <- grep(paste0("^struct ", struct, " \\{"), header)
  end <- start + grep("^\\};", header[-seq_len(start)])[1]
  body <- header[start:end]
  c(sub(".*void \\*(reserved[0-9]+);.*", "\\1", grep("void \\*reserved[0-9]+;", body, value = TRUE)),
    sub(".*\\(JNICALL \\*([A-Za-z0-9_]+)\\).*", "\\1", grep("JNICALL \\*", body, value = TRUE)))
}
offsets <- function(struct) sprintf('  printf("%s.%%s %%lu\\n", "%s", (unsigned long) offsetof(struct %s, %s));',
                                     struct, members(struct), struct, members(struct))
types <- c("jbyte", "jboolean", "jchar", "jshort", "jint", "jlong", "jfloat", "jdouble", "jsize",
           "jvalue", "jobject", "jfieldID", "jmethodID", "JavaVMOption", "JavaVMInitArgs", "JavaVMAttachArgs")
fields <- c("JavaVMInitArgs, version", "JavaVMInitArgs, nOptions", "JavaVMInitArgs, options",
            "JavaVMInitArgs, ignoreUnrecognized", "JavaVMOption, extraInfo", "JavaVMAttachArgs, group")
probe <- c("#include <stdio.h>", "#include <stddef.h>", "#include <jni.h>", "int main(void) {",
  sprintf('  printf("sizeof %s %%lu\\n", (unsigned long) sizeof(%s));', types, types),
  sprintf('  printf("offsetof %s %%lu\\n", (unsigned long) offsetof(%s));', fields, fields),
  offsets("JNIInvokeInterface_"), offsets("JNINativeInterface_"),
  '  printf("JNI_VERSION_1_2 %x\\n", JNI_VERSION_1_2);', "  return 0;", "}")
dir <- tempfile("jni-abi-")
dir.create(dir)
src <- file.path(dir, "probe.c")
writeLines(probe, src)
cc <- system2(file.path(R.home("bin"), "R"), c("CMD", "config", "CC"), stdout = TRUE)
run <- function(name, includes) {
  exe <- file.path(dir, paste0("probe-", name, if (windows) ".exe" else ""))
  command <- paste(cc, paste0("-I", quote(includes), collapse = " "), "-o", quote(exe), quote(src))
  if (system(command) != 0L) stop("cannot compile the probe with ", paste(includes, collapse = ", "))
  system2(exe, stdout = TRUE)
}
# A directory holding only rJava's header, so that no JDK header can be picked up.
own <- file.path(dir, "own")
dir.create(own)
stopifnot(file.copy(file.path("src", "jni.h"), own))
expected <- run("own", own)
stopifnot(length(expected) == length(types) + length(fields) + 1L +
          length(members("JNIInvokeInterface_")) + length(members("JNINativeInterface_")))
for (home in homes) {
  include <- file.path(home, "include")
  actual <- run(basename(tempfile("jdk")), c(include, list.dirs(include, recursive = FALSE)))
  different <- setdiff(expected, actual)
  if (length(different)) stop("JNI layout differs from ", home, ":\n", paste(different, collapse = "\n"))
  cat("JNI layout of src/jni.h matches", home, "(", length(expected), "entries )\n")
}

# test_rjava_win.R

# 1. Load the package.
# Expected behavior: Should NOT fail even if JAVA_HOME is unset or invalid initially,
# because we removed the hard link to jvm.dll.
library(rJava)
message("rJava loaded.")

# 2. Check JVM state
# Expected: "not-loaded" or "none"
print(rJava::.jvmState())

# 3. Simulate user setting JAVA_HOME after loading
# REPLACE THIS PATH with a valid JDK path on your Windows machine for testing!
# e.g. "C:/Program Files/Java/jdk-11"
my_java_home <- Sys.getenv("JAVA_HOME")
if (my_java_home == "") {
  warning("Please set a valid JAVA_HOME for this test script to run fully.")
} else {
  Sys.setenv(JAVA_HOME = my_java_home)
  message("JAVA_HOME set to: ", my_java_home)
}

# 4. Initialize
# Expected: Should find jvm.dll inside the JAVA_HOME set above and load it via LoadLibrary
.jinit()

# 5. Verify
print(rJava::.jvmState())
v <- .jcall("java/lang/System", "S", "getProperty", "java.version")
message("Java Version Loaded: ", v)

if (nzchar(v)) {
  message("SUCCESS: JVM loaded dynamically on Windows.")
} else {
  stop("FAILURE: JVM did not load.")
}

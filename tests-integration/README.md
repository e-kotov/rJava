# Deferred JVM loading experiment

This branch ports Simon Urbanek's `feature/dynamic` work onto upstream master
(`534ff33`) and includes Egor Kotov's earlier Windows loader work. It is an
experimental fork, not a released rJava API contract.

The acceptance boundary is **before the first JVM library load**. Loading the
rJava namespace, including through another package's Imports, must not select,
load, or initialize Java. `.jinit()` discovers the selected JVM at call time.
An invalid explicit Java home fails at initialization, allowing correction and
retry while no library has loaded. On Windows, registry discovery is deferred
until initialization too.

`dynamic.yaml` builds an actual source distribution with `sh mkdist`, installs
it in an isolated R library, and tests it on native Linux, macOS, and Windows
runners with Temurin 17 and 21. Every scenario uses a new R process. The native
library must have no direct JVM linkage. Tests cover selection after namespace
load, recovery after missing-library/missing-JNI-export errors, JNI calls,
and rejection of unloading any selected JVM library. They also install the rJavaEnv
feature branch and its two minimal downstream packages to test real Imports,
setup, startup, compatible guards, and child-process isolation.

To run locally, build and install the source tarball in a temporary library,
then set `R_LIBS` to it and `RJE_JAVA_HOME_A`/`RJE_JAVA_HOME_B` to two real JDK
homes. Run `Rscript --vanilla tests-integration/deferred.R select`, `retry`, and
`unload` as separate commands. The last case checks that unloading and changing
a selected, unstarted runtime both fail cleanly, then starts that same runtime.

## Limits

Namespace loading is different from JVM library loading, which is different
from JVM startup. Calling `.jloadJVM()` fixes the runtime selection boundary
even before `.jinit()`. A successful OS-level unload does not establish that
all runtime symbols and dependencies were removed. In a local macOS experiment,
loading Java 17, unloading before startup, then starting Java 27 failed with a
Java 17/27 symbol mismatch. Do not use `.junloadJVM()` to switch JDKs.

A selected JVM library cannot be unloaded by this R API, even before startup. Restarting a worker process
remains the supported way to run another JVM. A package that calls `.jinit()`
in `.onLoad()` still selects Java during package loading; this branch cannot
make that package's initialization lazy.

The hosted matrix covers current 64-bit R and two Temurin versions. It does not
establish compatibility for 32-bit Windows, every vendor, JDK 8, Java embedding
R through JRI, or every downstream package. The source build includes JRI, but
embedding/attach behavior requires separate regression testing before upstream
release.

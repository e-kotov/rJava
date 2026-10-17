# Deferred JVM loading experiment

This branch ports Simon Urbanek's `feature/dynamic` work onto upstream master
(`534ff33`) and includes Egor Kotov's earlier Windows loader work. It is an
experimental fork, not a released rJava API contract. Green CI jobs show that
the cases below work on hosted runners. They do not establish production
safety for every system.

## Contract

Loading the rJava namespace, including through another package's Imports,
does not select, load, or initialize Java. The first `.jinit()` (or
`.jloadJVM()`) selects a JVM library, in this order:

1. A JVM already created in the process, e.g. by a Java application
   embedding R through JRI: rJava attaches to it whatever Java home is
   configured. That is the only runtime the process can use, and rJava
   linked against the JVM library behaved the same way.
2. `getOption("java.home")` (Windows only, as before) or `JAVA_HOME`. A value
   that is not an existing directory is ignored with the upstream warning,
   as rJava did on Windows and macOS before deferred loading.
3. Windows: `CurrentVersion` of the JavaSoft registry keys (HKLM, then HKCU).
4. macOS: `/usr/libexec/java_home`.
5. The `java.home` property of `java` on `PATH`.

Within a Java home, known layouts are checked first (`lib/server`,
`jre/lib/<arch>/server`, `jre/lib/server`, `bin/server`, `jre/bin/server`),
then a recursive search. An existing Java home without a JVM library is an
error. Every failure before a library is loaded leaves the state
`"not-loaded"`, so the setting can be corrected and `.jinit()` retried.

If another JVM library is mapped into the process without a created VM,
only the same file can be selected. Identity is the file, not its name:
device and inode on Linux and macOS, volume serial and file ID on Windows.
So symbolic links, junctions, 8.3 short names and other spellings of the
loaded library are accepted, and djni references the mapped module rather
than loading the alias. A different or unverifiable file is rejected.

## Selected libraries are not unloaded

`.junloadJVM()` errors whenever a JVM library is loaded, even before a VM was
created. This is a deliberate safety boundary, separate from the Windows port
(commit "fix: retain JVM library selection until the R process exits").
`dlclose()`/`FreeLibrary()` success does not mean the library was unmapped:
macOS dyld never unloads images with thread-local variables, and libjvm has
them. In local macOS probes, loading Corretto 17 or Temurin 27, unloading it
before any VM was created, then starting another JDK failed with symbols
resolved against the first library. After `DestroyJavaVM`, creating a VM
from the same library failed (`JNI_ERR`), and switching from Corretto 17 to
Temurin 17 crashed in libjvm.
Use a new R process to run another JVM. `djni_unload()` remains only to
clean up a library that lacks the JNI entry points, and for Simon's
standalone `DJNI_MAIN_TEST` probe.

## Windows DLL search state

To load `jvm.dll`, djni adds the JDK `bin` directory (the parent of
`bin\server`, needed for JDK 8's C runtime) with `AddDllDirectory` only for
that `LoadLibraryExW` call, then removes it after success or failure. `PATH`
is never changed. `dll-search.c` checks the removal with a positive control.

Later native loads by the JVM (`zip`, `net`, `nio`, `management`,
`sunmscapi`, `awt`, `fontmanager`, `freetype`) work with `PATH` reduced to
system and R directories, for both JDKs of every Windows job. JDK libraries
that import each other resolve as already-loaded modules. The logged module
lists show the one external later dependency: `awt.dll` (and on JDK 8 also
`sunmscapi.dll`) imports the VC++ runtime (`MSVCP140.dll`, and
`VCRUNTIME140_1.dll` on JDK 8), which Windows then looks for in System32 and
on `PATH`, not in the JDK. Upstream rJava has the same exposure, because it
restores `PATH` right after linking `jvm.dll`.

The Windows job therefore hides System32's VC++ runtime DLLs, as on a
machine without the VC++ redistributable (for example with a JDK unpacked
from a zip archive and not on `PATH`). JVM startup must still succeed, and
does for all six JDKs: the scoped `bin` search covers `jvm.dll` and its
startup libraries. The later loads then fail, as recorded in the log, with
"Can't find dependent libraries": `sunmscapi.dll` on Temurin 8, and
`awt.dll` on Temurin 11, 17 and 21, Corretto 11 and Zulu 25. This branch
does not change that.

Options for maintainers, **not implemented**: (1) append the JDK `bin`
directory to `PATH` after selection, as an installer that adds Java to
`PATH` effectively does; this persists for the process and its children.
(2) After loading `jvm.dll`, load the VC++ runtime DLLs bundled in the JDK
`bin` only if System32 has none; the process then binds every later import
of those names to the JDK's copies, possibly older than a copy another
component bundles. Both are permanent process-wide changes that upstream
never made.

## Tests

Every scenario runs in a new R process with `PATH` reduced to system and R
directories and `JAVA_HOME` set explicitly, so the runner's Java setup cannot
mask discovery or dependency failures. `dynamic.yaml` builds a source
distribution with `sh mkdist`, installs it in an isolated library, and runs:

| Check | What it shows |
|---|---|
| linkage | `rJava.so`/`rJava.dll` has no JVM library dependency |
| `jni-abi.R` | `src/jni.h` type sizes, invocation struct fields and every function table offset match each JDK's `jni.h` |
| `select`, `retry`, `badinput` | selection after namespace load; recovery after an empty home, missing file, library without JNI exports, empty, over-long and relative paths |
| `unload` | unloading or changing a selected, unstarted library fails |
| `preloaded`, `preloaded global` | a library mapped outside rJava (also with global symbols) rejects another runtime and permits the same one |
| `alias link/spelling/short` | the same preloaded library through a symbolic link or junction with spaces and non-ASCII characters, an alternative spelling, and an 8.3 name (Windows) |
| `nonascii` | loading through such a path without a preload |
| `fallback` | invalid `JAVA_HOME` warns and falls back to an independently computed home (HKCU registry entry on Windows, `java_home` on macOS, `java` on PATH on Linux) |
| `laterload` | the later native loads above |
| `hosted` | native code creates a JVM, then `.jinit()` attaches to it although `JAVA_HOME` names the other JDK |
| `jengine`, `jri.R` | JRI started from R; a Java host embedding R, where rJava attaches to the host JVM (Linux and macOS) |
| `dll-search.c` | Windows DLL search state after failed and successful loads |
| downstream | rJavaEnv and two minimal consumer packages (current pair only) |

Bounded matrix, each on Linux, macOS (arm64) and Windows with R release; the
build JDK is Temurin 17:

| Set | JDK A | JDK B |
|---|---|---|
| legacy | Temurin 8 (Zulu 8 on macOS) | Temurin 11 |
| current | Temurin 17 | Temurin 21 |
| vendor | Corretto 11 | Zulu 25 |

The upstream `check.yaml` matrix (R devel, Zulu 8 and 11, five runner images
including Intel macOS) also runs on this branch.

To run locally, build with `sh mkdist`, install the tarball in a temporary
library, set `R_LIBS` to it and `RJE_JAVA_HOME_A`/`RJE_JAVA_HOME_B` to two JDK
homes, and run `Rscript --vanilla tests-integration/deferred.R <scenario>`
from the repository root, one process per scenario.

## Limits

- Namespace loading, JVM library loading and JVM startup are different
  boundaries. `.jloadJVM()` fixes the selection even before `.jinit()`. A
  package that calls `.jinit()` in `.onLoad()` still selects Java when it
  loads.
- Attaching to a JVM created by a host requires rJava's `java/boot` on the
  host's class path on JDK 9+, as before: rJava cannot add it to a running
  application class loader there.
- Windows source installs build no JRI, as on upstream master:
  `configure.win` still looks for `jri/` although JRI moved to `src/jri` in
  1.0-15, and `src/jri/Rdecl.h` includes `<Rinterface.h>`, which R does not
  ship on Windows. JRI embedding is therefore tested on Linux and macOS only;
  attaching to a created JVM is tested on Windows with the native helper.
- Windows AWT later loads depend on a VC++ runtime outside the JDK, as above.
- Not covered: 32-bit Windows, Windows on ARM, Linux on ARM, musl, OpenJ9 and
  other non-HotSpot VMs, Java runtimes without a JDK layout, R versions other
  than current release (and devel in `check.yaml`), and downstream packages
  beyond the two test consumers.

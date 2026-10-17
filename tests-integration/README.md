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

If a JVM library is already mapped into the process, a path given to
`.jloadJVM()`, or found from a Java home, selects it only if it names the
mapped file, whether or not that library has created a VM. djni finds mapped JVM libraries among
all images the dynamic loader lists (`dl_iterate_phdr` on Linux, dyld on
macOS, `EnumProcessModules` on Windows), without loading anything. An image
is a JVM library if it has a JVM library name (`libjvm.so`, `libjvm.dylib`,
`jvm.dll`), even if malformed, or whatever its name if it defines itself
`JNI_CreateJavaVM`, `JNI_GetCreatedJavaVMs` and `JVM_CurrentTimeMillis`.
"Defines itself" excludes definitions inherited from a dependency
(the symbol address lies outside the image) and forwarded Windows exports
(read from the export table in memory). JNI exports alone do not suffice:
rJava's own wrappers have them, and so does the macOS `libjli`, which
forwards them to libjvm. Every HotSpot JDK in the matrix exports the three
symbols; CI checks this for each runtime.

Identity is then the file, not its name: device and inode on Linux and
macOS, volume serial and file ID on Windows. The mapped side is the file the
image was mapped from, not the file now at the name the loader recorded,
which may have been deleted or replaced since: on Linux the mapping's entry
in `/proc/self/maps`, on macOS the vnode of the mapped region
(`proc_pidinfo` with `PROC_PIDREGIONPATHINFO`), on Windows the file
`GetMappedFileNameW` names for the module, opened by its device path. So an
upgrade that replaces the loaded library's file is not taken for the new
runtime, and the same file is still accepted under any of its names.
Symbolic links, junctions,
hard links, 8.3 short names, other spellings and renamed copies of the
loaded library are recognized: the same file is accepted, and djni
references the mapped image rather than loading the alias. On Windows the
same file is rejected if mapped under another module name than `jvm.dll`:
the JDK's DLLs import `jvm.dll` by name, and the loader matches loaded
modules by base name, so starting a VM would load another `jvm.dll` or
fail. A different or
unverifiable file is rejected, and so is any selection while more than one
JVM image is mapped (`RgetMappedJVM` then reports one of them with `vms`
`-1`). If the loaded images cannot be listed, selection fails and
`RgetMappedJVM` signals an error, so callers do not mistake it for "none".

### Explicit selection and attaching

Selecting a path and attaching to a created VM are separate operations.
`.jloadJVM(path)` always compares files as above; no name is exempt, not
even the one `RgetMappedJVM` reports for a created VM, since the file now
at that name may be another runtime. `.jinit()` instead attaches through
the internal `RattachJVM`, which takes no path: it requires exactly one
mapped JVM image, with at least one created VM, and selects that image
through the reference djni holds to it, without loading anything. So it
attaches even if the file at the image's recorded name was deleted or
replaced, or cannot be identified (overlayfs, below). It never selects an
image without a created VM, never resolves an ambiguity between several
images, and fails if the image lacks a JNI entry point. On Windows it does
not apply the `jvm.dll` name rule, which concerns starting a VM (untested:
the JDK cannot start a VM from a renamed `jvm.dll`). No
exported function attaches without a path.

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
| `preloaded`, `preloaded global` | a library mapped outside rJava (also with global symbols) rejects another runtime and permits the same one; `RattachJVM` fails with nothing mapped and with no created VM |
| `alias link/spelling/short` | the same preloaded library through a symbolic link or junction with spaces and non-ASCII characters, an alternative spelling, and an 8.3 name (Windows) |
| `renamed copy/hardlink/symlink` | a JVM library mapped under a name no JVM uses: a copy of B rejects A and B's own library; a hard link of A in its directory (and a symbolic link, Linux and macOS) rejects B, then the same file starts A (Windows: is rejected as mapped under another name) |
| `hosted renamed` | native code creates the VM from the hard link; it is reported with one VM, B is rejected, and `.jinit()` attaches (Linux and macOS) |
| `replaced deleted/replaced` | the file of the mapped library is deleted, or replaced by a hard link of B's (Windows: a mapped DLL cannot be deleted, so it is renamed in a copy of A's home and B's linked as `jvm.dll`): B, the replaced name and `.jinit()` with `JAVA_HOME` naming B are rejected, A's own file is accepted, and after replacement A starts |
| `hosted replaced` | the same replacement after a host created the VM (Windows: renamed in a copy of A's home, as above): `.jloadJVM()` rejects B, the replaced name and the name `RgetMappedJVM` reports, all before `.jinit()` attaches to A |
| `decoy` | the JDK's `jli` library (JNI exports on macOS, no `JVM_` exports) is not reported and does not block selecting B |
| `nonascii` | loading through such a path without a preload |
| `fallback` | invalid `JAVA_HOME` warns and falls back to an independently computed home (HKCU registry entry on Windows, `java_home` on macOS, `java` on PATH on Linux) |
| `laterload` | the later native loads above |
| `hosted`, `hosted explicit` | native code creates a JVM, then `.jinit()` attaches to it although `JAVA_HOME` names the other JDK; `.jloadJVM()` rejects B, and with `explicit` selects A's own file first |
| every scenario | before anything is mapped, `RgetMappedJVM` is `NULL`: rJava's own JNI wrappers are not taken for a JVM |
| `jengine`, `jri.R` | JRI started from R; a Java host embedding R, where `.jloadJVM()` rejects the `JAVA_HOME` runtime and rJava attaches to the host JVM (Linux and macOS) |
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
- Mapped JVM discovery covers Linux, macOS and Windows only; elsewhere djni
  lists no mapped libraries, so it cannot reject a conflict. It cannot see libraries
  in another `dlmopen()` namespace, and identifies a renamed JVM only by
  the exports above (a JVM without `JVM_CurrentTimeMillis` must keep its
  usual name). If the mapped file cannot be identified (no `/proc` on
  Linux, a failed query), selection is rejected. On overlayfs (e.g. Docker)
  with Linux before 6.8, `/proc/self/maps` reports the layer file's device,
  while `stat()` reports the overlay's, so `.jloadJVM(path)` rejects a
  mapped library as unverifiable even when it is the same file, with or
  without a created VM; `.jinit()` attaching to a created VM is unaffected,
  as it compares no files. This
  follows from the kernel source (`show_map_vma` uses `file_user_inode`
  only from 6.8) and is not tested. dyld
  records a library loaded through a symbolic link by its target, so on
  macOS the `symlink` variant shows the target name.
- Not covered: 32-bit Windows, Windows on ARM, Linux on ARM, musl, OpenJ9 and
  other non-HotSpot VMs, Java runtimes without a JDK layout, R versions other
  than current release (and devel in `check.yaml`), and downstream packages
  beyond the two test consumers.

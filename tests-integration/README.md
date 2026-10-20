# Deferred JVM loading experiment

This branch ports Simon Urbanek's `feature/dynamic` work onto upstream master
(`534ff33`) and includes Egor Kotov's earlier Windows loader work. It is an
experimental fork, not a released rJava API contract. Green CI jobs show that
the cases below work on hosted runners. They do not establish production
safety for every system.

## Contract

Loading the rJava namespace, including through another package's Imports,
does not select, load, or initialize Java. The first `.jinit()` selects a
JVM library in this order:

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
"Defines itself" excludes definitions inherited from a dependency and
forwarded Windows exports. The exports are read without a handle where a
handle may be unavailable: on Linux from the image's dynamic symbol table in
memory (located through its `PT_DYNAMIC` segment and hash table, as the
dynamic loader reads it), on Windows from the export table in memory. On
macOS, `dlsym()` on a `RTLD_NOLOAD` handle must return an address inside the
image. On Linux, an image whose table cannot be read inside its own readable
segments makes discovery fail, rather than being taken for no JVM. JNI
exports alone do not suffice:
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
through a reference to it, without loading anything. So it attaches even if
the file at the image's recorded name was deleted or replaced, or cannot be
identified (overlayfs, below), as long as a reference can be taken (below
for musl). It never selects an
image without a created VM, never resolves an ambiguity between several
images, and fails if the image lacks a JNI entry point. On Windows it does
not apply the `jvm.dll` name rule, which concerns starting a VM (untested:
the JDK cannot start a VM from a renamed `jvm.dll`). The native attach entry
point has no exported R wrapper.

## The JVM library name on Linux

The JDK's own libraries (`libjava`, `libjimage`, `libzip`, ...) depend on
`libjvm.so` by name, with only their own directory (`$ORIGIN`) as run path,
not `server`. glibc matches that name to the loaded JVM library by its
SONAME. musl does not: it matches only a library it found by searching, and
searches `LD_LIBRARY_PATH` as set when the process started, then its system
path. With a JVM library selected by path, the name is then not found, or
names another runtime. R's `etc/ldpaths` puts `R_JAVA_LD_LIBRARY_PATH` on
`LD_LIBRARY_PATH`, by default `lib/server` of `JAVA_HOME` at R startup or of
the `R CMD javareconf` JDK. On Alpine, with JDK 17 configured, `.jinit()`
with `JAVA_HOME` naming another runtime failed while the VM loaded the JDK's
libraries: `libjava.so: JVM_DoPrivileged: symbol not found` with OpenJDK 11,
consistent with binding to JDK 17's `libjvm.so`, which lacks that symbol,
and `Unable to load jimage library` with OpenJDK 21.

So on Linux, after loading the library and its JNI entry points, djni
resolves `libjvm.so` with `RTLD_NOLOAD`, which loads nothing, and refuses the
selection unless the name resolves to the selected library. The refusal
happens before a VM is created and leaves the state `"not-loaded"`, but musl
never unmaps a library, so it remains mapped and blocks other selections: use
a new R process started with `JAVA_HOME` naming the runtime, or
`R_JAVA_LD_LIBRARY_PATH` naming its server directory (needed for the JDK 8
layout). On glibc the name resolves through the SONAME, so the check passes
in every glibc scenario above, including renamed and replaced names.
Changing `LD_LIBRARY_PATH` in a running process, as `deferred.R` does, does
not change musl's search path. A Java application
embedding R through JRI is not affected: for this reason the JDK launcher
built for musl sets `LD_LIBRARY_PATH` and re-executes itself
(`RequiresSetenv` in OpenJDK's `java_md.c`), and attaching checks no names.

musl also resolves `dlopen(name, RTLD_NOLOAD)` for a path by opening that
file and matching its device and inode (`load_library` in musl's
`ldso/dynlink.c`). A recorded name whose file was deleted or replaced then
yields no reference, or one to another mapped library. Earlier, djni read the
exports of an image through that reference, so on musl a JVM library mapped
under a name no JVM uses was no longer identified once its file was deleted or
replaced: in `replaced deleted` with B's server directory on the startup
library path, `.jloadJVM()` of B mapped B's library next to A's and succeeded,
as the name check then found B; with A's there, the name check refused B, but
only after mapping it. Now the exports are read from memory (above), so the
image is still identified and B is refused before anything is loaded. A
reference is taken only through a name the dynamic loader resolves to the
image itself, verified with `dlinfo(RTLD_DI_LINKMAP)` against the image's
dynamic section: its recorded name, then `libjvm.so` (the name the JDK's
libraries bind to), and for `.jloadJVM()` the path given, which must name the
mapped file. If none resolves to the image, selecting or attaching it is
refused (`Cannot reference the JVM library ...`) before a VM is created. The
`replaced` scenarios run on musl with A's and with B's server directory on
the startup library path, and check that nothing from B's home is mapped
after the refusals; with B's, A is refused too, by the name check.
`hosted replaced` runs with A's only: with B's, the host's own VM would bind
A's JDK libraries to B's `libjvm.so` before rJava is involved.

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
`sunmscapi`, `awt`, `fontmanager`, `freetype`) also need the JDK's MSVC runtime
DLLs to be resolvable by basename. After verifying the JNI entry points,
both explicit selection and host attachment retain the selected runtime's
MSVC DLLs. An already loaded copy is retained with `GetModuleHandleExW`;
it cannot safely be replaced. Otherwise a copy in the selected JDK's `bin`
is preferred, and System32 is used only when that bundled copy is absent.
This follows the normal `java.exe` preference for its own directory and
avoids selecting System32's older `msvcp140` after startup has already loaded
the JDK's `vcruntime140`. References last until process exit. No persistent
search directory or `PATH` change is made. A bundled DLL that exists but
fails to load is diagnosed on stderr rather than silently falling back to
a different copy. Missing optional DLLs are allowed; JDKs that omit a required
runtime still need a suitable redistributable.

The base VC++ DLLs and bundled `msvcp140_1`, `_2` and `_atomic_wait` satellites
are covered. Already loaded copies retain host-process precedence: this can
bind Java to a host's incompatible older runtime. Use a fresh process with
a compatible runtime in that case; the loader does not replace live DLLs.

Every Windows job tests normal System32 DLLs, their absence, and genuine
Microsoft VC++ 2015 Update 3 (14.0.24212.0) DLLs temporarily placed in System32.
The old installer is downloaded from Microsoft's distribution site and
pinned by SHA256; only its DLLs are extracted, and file versions must prove
they are older than each selected JDK's bundled copies. A clean-process
control loads the old System32 DLL. `msvc.R` then checks startup, late native
loads after host attachment, and actual loaded module paths for both JDKs.
The native host fixture selects its startup dependencies with a scoped JDK
`bin` search; rJava must resolve late dependencies independently after that
search scope has ended. A separate case releases the original reference to a preloaded MSVC DLL and
checks rJava's retained reference keeps it mapped. Java-host JRI also runs
without system DLLs and with the old copies. Files are restored in `finally`,
including on a failed test. These mutations occur only on disposable Actions
runners.

## Windows JRI builds

`configure.win` now builds JRI at its current location, `src/jri`, and
installs `JRI.jar` and `jri.dll` alongside rJava. The Windows Makefiles set
explicit default targets so R's included Makeconf cannot select an unrelated
rule. Windows uses its own console declaration instead of the Unix-only
`Rinterface.h`; the x64 build also enables JRI's existing Win64 branches.

JRI is built by default, and a build failure stops installation. To omit it
explicitly, use `JRI=0 R CMD INSTALL rJava_<version>.tar.gz`; normal rJava/JNI
functionality remains available. `IGNORE=1 R CMD INSTALL ...` instead attempts
JRI and permits installation if that optional build fails. CI forces a real
`javac` failure to check the default failure and `IGNORE=1` fallback, and tests
the explicit `JRI=0` path. A full JDK is needed to build JRI.

`WIN64` is derived from the compiler's `_WIN64`, independently of `R_ARCH`.
The Windows import declaration for `UserBreak` comes from R's header on R
4.6+ and a compatibility declaration on older R. Generated JNI headers are
normalised to LF, avoiding a Windows-only line-ending check NOTE. The Java
host test interrupts a sleeping R evaluation through `rniStop` and requires
both interrupt delivery and subsequent R evaluation to succeed.

Every Windows runtime pair now runs `.jengine()` from R and a Java host
embedding R through JRI. The latter runs with both JDKs as host, with
`JAVA_HOME` deliberately naming the other runtime. The test requires rJava
to reject that other runtime and attach to the host's already running JVM.

## Overlayfs kernel checks

`overlay.yaml` boots real QEMU/KVM guests; a container alone would reuse the
runner's kernel. Ubuntu image snapshots and the frozen mainline kernel are
pinned by SHA256. Reboot readiness checks the boot ID rather than sleeping
for a fixed duration. Each guest records its actual kernel and mounts.

Each kernel exercises four layouts: all layers on one filesystem, separate
ext4 filesystems with `xino=off`, separate ext4 filesystems with `xino=on`,
and a rootless mount created in an unprivileged user's user namespace.
Tests on privileged mounts run as the unprivileged user too. Each layout
covers a fresh JVM, a preloaded library, a host-created JVM, and replacement
of the mapped file, in separate R processes. Module identities and `stat()`
identities are logged; assertions distinguish a definite different-file
refusal from an unverifiable overlay identity.

The kernels are Ubuntu 22.04's 5.15, Ubuntu 24.04's 6.8, and frozen mainline
6.1.0 (`6.1.0-060100.202303090726`). Older kernels with the mapping-identity
limitation reject ambiguous same-file reuse, while fresh startup and host
attachment work. Cross-filesystem `xino=off` also produces a device mismatch on these modern
kernels, so preloaded path selection is conservatively refused there too. A
device mismatch is unverifiable, while equal devices with
different inodes are definitely different files. A distro version below
6.8 alone does not predict the behavior, so fixtures assert the expected
behavior for the actual layout and record the kernel.

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
| `replaced deleted/replaced` | the file of the mapped library is deleted, or replaced by a hard link of B's (Windows: a mapped DLL cannot be deleted, so it is renamed in a copy of A's home and B's linked as `jvm.dll`): B, the replaced name and `.jinit()` with `JAVA_HOME` naming B are rejected, and on Linux nothing from B's home is then mapped; A's own file is accepted, and after replacement A starts (musl with B's server directory on the startup library path: A is refused by the name check instead, and B is still not mapped) |
| `hosted replaced` | the same replacement after a host created the VM (Windows: renamed in a copy of A's home, as above): `.jloadJVM()` rejects B, the replaced name and the name `RgetMappedJVM` reports, nothing from B's home is mapped (Linux), all before `.jinit()` attaches to A |
| `decoy` | the JDK's `jli` library (JNI exports on macOS, no `JVM_` exports) is not reported and does not block selecting B |
| `nonascii` | loading through such a path without a preload |
| `byname` | musl, with A's server directory on the startup library path: selecting B is refused before a VM exists, A's library is not mapped, and the B library that musl keeps mapped then blocks A |
| `fallback` | invalid `JAVA_HOME` warns and falls back to an independently computed home (HKCU registry entry on Windows, `java_home` on macOS, `java` on PATH on Linux) |
| `laterload` | the later native loads above |
| `hosted`, `hosted explicit` | native code creates a JVM, then `.jinit()` attaches to it although `JAVA_HOME` names the other JDK; `.jloadJVM()` rejects B, and with `explicit` selects A's own file first |
| every scenario | before anything is mapped, `RgetMappedJVM` is `NULL`: rJava's own JNI wrappers are not taken for a JVM |
| `jengine`, `jri.R` | JRI started from R; a Java host embedding R, where `.jloadJVM()` rejects the `JAVA_HOME` runtime and rJava attaches to the host JVM (all three platforms, both host JDKs) |
| `dll-search.c` | Windows DLL search state after failed and successful loads |
| `msvc.R` | Windows normal/missing/2015 system runtimes, retained references, fresh startup and hosted late loads; loaded runtime origins |
| `overlay.R` | actual 5.15, 6.1.0 and 6.8 kernels; four overlay layouts, unprivileged processes, exact refusal classes |
| downstream | rJavaEnv and two minimal consumer packages (current pair only) |
| `xlsx.R`, xlsx check | the CRAN package xlsx, whose `.onLoad()` starts Java through `.jpackage()`: loading it selects `JAVA_HOME` (JDK B, not the build JDK on `PATH`), another runtime is then rejected, and a workbook round trip works; `R CMD check` of the CRAN source package runs its testthat suite (current pair only) |
| `musl.sh` | the Linux scenarios above, `byname` and `jri.R` on Alpine, each scenario with the server directory of the runtime it starts on the startup library path; `replaced deleted/replaced` also with B's, `hosted replaced` with A's only (above) |

Bounded matrix, each on Linux (x86_64 and arm64), macOS (arm64) and Windows
with R release; the build JDK is Temurin 17. On Linux arm64, JDK 8 has the
`jre/lib/aarch64/server` layout:

| Set | JDK A | JDK B |
|---|---|---|
| legacy | Temurin 8 (Zulu 8 on macOS) | Temurin 11 |
| current | Temurin 17 | Temurin 21 |
| vendor | Corretto 11 | Zulu 25 |

An additional Windows R 4.5 job runs the same native, JRI and VC++ checks
with Temurin 17/21, including the console declarations for R before 4.6. An
Ubuntu 24.04 job runs the native and JRI checks with R 3.6.3, the oldest R
that `DESCRIPTION` accepts, and Temurin 17/21.

The musl jobs run `musl.sh` in Docker from a pinned `alpine:3.24.2` image:
musl 1.2.6, Alpine's R 4.6.0 and its OpenJDK packages. Their libraries must
link `libc.musl`, not a glibc compatibility layer. The JDKs are installed in
the container's overlayfs root on the runner's current kernel, as in a
typical Docker deployment:

| Set | Machine | JDK A | JDK B |
|---|---|---|---|
| legacy | x86_64 | OpenJDK 8 | OpenJDK 11 |
| current | x86_64 | OpenJDK 17 | OpenJDK 21 |
| current | aarch64 | OpenJDK 17 | OpenJDK 21 |

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
- Mapped JVM discovery covers Linux, macOS and Windows only; elsewhere djni
  lists no mapped libraries, so it cannot reject a conflict. It cannot see libraries
  in another `dlmopen()` namespace, and identifies a renamed JVM only by
  the exports above (a JVM without `JVM_CurrentTimeMillis` must keep its
  usual name). If the mapped file cannot be identified (no `/proc` on
  Linux, a failed query), selection is rejected. On overlayfs (e.g. Docker),
  kernels without the mapping-identity fix can report the layer file's
  device/inode in `/proc/self/maps` while `stat()` reports the overlay's.
  `.jloadJVM(path)` then rejects a mapped library as unverifiable, even when
  it is the same file, with or without a created VM. A new R process can
  select it normally; `.jinit()` attaching to a created VM compares no files.
  This is exercised on the frozen mainline 6.1.0 guest, alongside successful
  reuse on the current Ubuntu 5.15 and current-kernel guests. dyld
  records a library loaded through a symbolic link by its target, so on
  macOS the `symlink` variant shows the target name.
- On musl, a process can start only the runtime whose server directory was on
  `LD_LIBRARY_PATH` when it started (above). Other runtimes are refused, not
  supported, and the refused library stays mapped, so retrying in the same
  process with another runtime is refused too: start a new R process. A JVM
  library mapped under a name that no longer opens it is identified, but can
  be selected or attached only through a name that still resolves to it
  (above); otherwise rJava refuses it.
- Not covered: 32-bit Windows; Windows on ARM (the linkage, JRI and VC++
  fixtures assume x64, and the old VC++ runtime test downloads x64 DLLs);
  OpenJ9 and other non-HotSpot VMs, which the export-based identification
  above does not describe; Java runtimes without a JDK layout; musl JDKs
  other than Alpine's packages (e.g. Temurin's Alpine builds), and JDK 8 on
  musl arm64; Intel macOS in this matrix (only in `check.yaml`); R versions
  other than release, Windows 4.5, Linux 3.6.3 and devel in `check.yaml`;
  and downstream packages beyond rJavaEnv, the two test consumers and xlsx.

Modifying a mapped JVM library in place without changing its device/inode is
outside the identity guarantee, as for other native libraries. Replace runtime
files atomically and use a fresh process after an upgrade. The tests exercise
unlink/replacement, not arbitrary writes to live native-code mappings.

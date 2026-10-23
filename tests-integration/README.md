# Deferred JVM loading: fork test harness

This directory and the added workflows are fork-only validation infrastructure.
The upstream candidate excludes them, Windows JRI build changes, and MSVC
runtime retention. The original preview is preserved at
`archive/dynamic-preview-cd6bbe5` for comparison and follow-up work.

## Runtime contract

Loading the namespace does not select or load a JVM library. First `.jinit()`:

1. Attaches to the single JVM already created in the process, regardless of
   Java-home settings.
2. Otherwise uses the Windows `java.home` option or `JAVA_HOME`.
3. Tries the JavaSoft registry on Windows, `/usr/libexec/java_home` on macOS,
   or `R CMD config JAVA_HOME` on Linux, preserving the javareconf default.
4. Falls back to the `java.home` property from `java` on `PATH`.

Invalid directory settings warn and fall back. An existing Java home without
any JVM library is an error. Failed selection can be retried only while no
JVM library remains mapped. A selected library cannot be unloaded or switched;
use a new R process. `RJAVA_FORCE_LOAD` is no longer used. Dynamic loading is
mandatory; `--disable-dynload` is rejected explicitly.

A path selects an already mapped JVM only when its identity can be verified.
Linux compares the mapped inode and device in `/proc/self/maps` with `stat()`.
Device numbers can differ on btrfs and overlayfs. Equal inodes on differing
devices additionally require `dlopen(path, RTLD_NOLOAD)` to return the exact
image, verified by `dlinfo(RTLD_DI_LINKMAP)` against its dynamic section. That
lookup never maps a second library. Different inodes with matching devices
are different files; unverifiable identities are refused. In particular,
inode equality across btrfs subvolumes alone is insufficient.

Mapped libraries are recognized by their name or their own JNI invocation
exports plus `JVM_CurrentTimeMillis`. Renamed/deleted JVM recognition is
retained because it prevents a second JVM being mapped on musl. JNI exports
alone do not identify a JVM (`rJava` and macOS `libjli` have them too).
Linux reads image metadata only inside the `dl_iterate_phdr` callback.
VM counts use a fresh symbol lookup through the held image reference on
Linux; only musl may use a saved address without a reference, since its
`dlclose` never unmaps the image.

## GitHub worker checks

`dynamic.yaml` builds the distribution, installs it into an isolated R library,
and checks the native library has no JVM dependency. It runs each scenario
in a fresh R process, with Java removed from PATH except in discovery tests:

- Selection, retry after load failure, invalid paths, and refusal to unload.
- Preloaded local/global libraries, hard links, symbolic links, spelling
  variants, Unicode paths, Windows junctions and short names.
- Renamed JVMs, deleted/replaced mapped names, refusal before mapping another
  runtime, and attachment to a VM created by native host code.
- Configured-JDK preference on Linux with a different Java on PATH; invalid
  explicit settings fall back to the platform default.
- JNI ABI compatibility against both JDK headers, JNI object/array/exception
  calls, and native libraries loaded after JVM initialization.
- Linux deterministic unmapping and concurrent discovery (`race`), with
  20,000 map/unmap cycles. Stress exercises the window, not a proof of safety.
- Java hosting R through existing JRI on Unix, in both runtime directions;
  R hosting JRI through `.jengine()` on Unix. Windows asserts that the
  proposal does not enable the previously unbuilt JRI path.
- Windows DLL search-directory cleanup, with a positive control.
- Explicit rejection of `--disable-dynload`, instead of silently ignoring it.
- rJavaEnv's downstream consumers and CRAN `xlsx`, including initialization
  from `.onLoad` and the package check.

The matrix covers Linux x86_64/arm64, macOS arm64, Windows x64, JDK 8/11,
17/21, Corretto 11 and Zulu 25, release R, Windows R 4.5 and Linux R 3.6.
Alpine's musl packages run on x86_64 and arm64, including deleted/replaced
aliases with either runtime's server directory on the startup library path.

`filesystems.yaml` mounts real loop-backed **btrfs and ext4** on disposable
Ubuntu workers. Native and R tests run unprivileged. The native fixture
builds both the pre-review loader at `cd6bbe5` and the candidate: the former
must reproduce the btrfs same-file refusal; the latter must accept the same
mapped file and refuse a different file without mapping it. A btrfs snapshot
also checks equal-inode files from distinct subvolumes are refused. R runs
preloaded/global, explicit host selection, aliases, renamed and replaced
scenarios against two JDKs on each mounted filesystem. Logs are artifacts.

`overlay.yaml` boots real QEMU/KVM kernels (Ubuntu 5.15, frozen mainline 6.1,
and Ubuntu 6.8), with pinned guest image/kernel checksums. Each kernel tests
same-filesystem layers, cross-filesystem xino on/off, and a rootless mount.
Fresh selection, preloaded selection, host attachment and replacement run as
an unprivileged user (or inside its user namespace). Actual mapping/stat
identities determine whether same-file reuse is verifiable; an old kernel
version alone does not predict it.

The existing upstream `check.yaml` additionally covers devel R and Intel macOS.
The fork-only workflows run on the testing branch and by manual dispatch.
They deliberately check out this fork's pinned rJavaEnv consumer; neither the
branch filters nor the consumer checkout is proposed upstream.

## Windows enhancement necessity experiment

Dispatch `dynamic.yaml` with `windows_comparison=true` to run only the
controlled Windows comparison, without rerunning the general matrix. Six
workers cover release R and R 4.5 with Temurin 8/21 and Zulu 25. Every worker
builds four source variants in isolated libraries:

- Upstream master at `534ff33` (also the upstream candidate's base).
- The unchanged candidate at `fdbe195`.
- The candidate plus only the MSVC retention function and its two call sites
  from `cd6bbe5`.
- The candidate plus only the Windows JRI build changes from `cd6bbe5`.

The master, candidate and MSVC-only builds run identical public rJava calls
in fresh R processes and after a native host creates Java. The workload uses
compression, loopback networking, SHA-256, JVM management, the Windows
certificate store, AWT drawing and PNG encoding. It verifies the selected
Java home and records loaded JVM/MSVC module paths before and after Java.
Java directories are absent from PATH.

Each workload runs with the hosted system's VC++ DLLs, with the named VC++
DLLs absent from System32, and with the original Microsoft VC++ 2015 Update 3
DLLs in System32. The old payload is pinned by SHA256 and version; DLLs are
restored in `finally`. All system changes happen only on disposable workers.
This models deployment conditions but is not a clean Windows image or a
measurement of how common those conditions are. R or another component may
already load its own runtime: module origins are essential to interpretation.

A master success / candidate failure is a regression to investigate. Shared
failure cured by MSVC retention is evidence for broader compatibility, not
evidence that deferred loading alone requires the enhancement. Shared success
shows no need for the enhancement in that specific tested case.

JRI tests compare bundling with a Java application supplying its own JRI
dependency. The external-JRI host uses the same JRI-only native library/jar
for each installed rJava variant; this isolates rJava attachment from JRI's
build and tests coexistence with existing embedding applications. The bundled
JRI positive control runs `.jengine(TRUE)`. With JDK 21, an intentionally bad
JRI compiler flag also demonstrates whether enabling the build can turn an
otherwise successful package install into a failure.

Workload failures are experimental observations in CSV/JSON and logs, not
silently skipped tests. Jobs fail on candidate-only regressions, unexpected
normal-system failures, setup errors, or failed JRI positive controls. Worker
summaries compare outcomes explicitly. PR #2's runtime sources are unchanged.

## Limits

- musl can start only the JVM whose server directory was on
  `LD_LIBRARY_PATH` at process start. `R_JAVA_LD_LIBRARY_PATH` can select that
  directory through R's launcher. Changing the environment inside R does not
  change musl's search path. A refused JVM remains mapped, so another choice
  then requires a new process.
- Linux has a window between listing an image and acquiring its reference.
  The loader compares identity and refreshes the VM-count symbol while the
  handle holds it mapped. The concurrency test cannot prove all native-thread
  interactions safe.
- macOS dyld enumeration can race with another native thread unloading **any
  library**, not only a JVM: the name/header and later export lookup may no
  longer describe the same mapped image. This is the same class of lifetime
  issue fixed on Linux; the current dyld enumeration offers no equivalent
  loader-lock guarantee. It remains an explicit limitation.
- The suite does not establish support for OpenJ9, ELF32/other Linux
  architectures, Windows ARM/32-bit, all R versions, or every downstream
  package that links directly to libjvm. Unreadable ELF metadata makes
  discovery fail safely rather than treating a mapped JVM as absent.
- Windows JRI building and retention of bundled MSVC runtimes are follow-up
  enhancements. This proposal preserves the existing Windows installation
  scope and relies on the installed system runtime for later native loads.
- In-place edits to mapped native code, or replacement/remounting with a
  colliding inode and a loader-cached path on another filesystem, cannot be
  established as a new runtime by the loader's cached-name identity. Use
  atomic runtime upgrades and a fresh process; the tested replacement cases
  use unlink/rename, not writes to live code or mount substitution.

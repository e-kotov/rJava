#!/bin/bash
# Runs the Linux deferred-loading checks against musl libc, R and OpenJDK
# from Alpine packages, inside an Alpine container:
#   docker run --rm -v "$PWD:/src:ro" alpine:3.24 \
#     sh -c 'apk add --no-cache bash && bash /src/tests-integration/musl.sh 17 21 x86_64'
# The arguments are the Alpine OpenJDK versions of JDK A and JDK B, and the
# expected machine. The source is copied first: mkdist writes into the tree
# and its parent.
set -euo pipefail
version_a="$1"
version_b="$2"
[[ "$(uname -m)" == "$3" ]] || { echo "::error::machine is $(uname -m), expected $3"; exit 1; }
apk add --no-cache build-base R R-dev binutils coreutils findutils grep \
  "openjdk$version_a-jdk" "openjdk$version_b-jdk" openjdk17-jdk
export LANG=C.UTF-8 LC_ALL=C.UTF-8
home() {
  local dir
  for dir in "/usr/lib/jvm/java-$1-openjdk" "/usr/lib/jvm/java-1.$1-openjdk"; do
    if [[ -d "$dir" ]]; then echo "$dir"; return; fi
  done
  echo "no Alpine OpenJDK $1 home" >&2
  return 1
}
export RJE_JAVA_HOME_A="$(home "$version_a")"
export RJE_JAVA_HOME_B="$(home "$version_b")"
export RJE_FALLBACK_HOME="$RJE_JAVA_HOME_B"
export JAVA_HOME="$(home 17)" NOAWT=1
export PATH="$JAVA_HOME/bin:$PATH"

echo "::group::Environment"
cat /etc/alpine-release
ldd --version 2>&1 | head -n 2 || true
uname -srm
R --version | head -n 1
# The container root is normally overlayfs on the runner's kernel.
stat -f -c 'JDK filesystem: %T' "$RJE_JAVA_HOME_A"
# deferred.R reduces PATH to /usr/bin:/bin so that a system java cannot mask
# discovery. Alpine's java-common links /usr/bin/java to the default JVM;
# remove that link in this disposable container, as the hosted jobs do not
# have one either.
ls -l /usr/bin/java /usr/lib/jvm/default-jvm 2>&1 || true
rm -f /usr/bin/java
if [[ -e /usr/bin/java || -e /bin/java ]]; then echo "::error::java on the reduced PATH would mask discovery"; exit 1; fi
echo "::endgroup::"

for jhome in "$RJE_JAVA_HOME_A" "$RJE_JAVA_HOME_B"; do
  echo "== $jhome"; "$jhome/bin/java" -version 2>&1
  find "$jhome/" -name 'libjvm.*' -print
  lib="$(find "$jhome/" -name 'libjvm.*' -path '*server*' -print -quit)"
  # These must be musl builds, not glibc builds run through a compatibility layer.
  readelf -d "$lib" | grep -E 'NEEDED.*libc\.musl-' || { echo "::error::$lib is not linked against musl"; exit 1; }
  syms="$(nm -D --defined-only "$lib")"
  for sym in JNI_CreateJavaVM JNI_GetCreatedJavaVMs JVM_CurrentTimeMillis; do
    if grep -Eq "[ _]$sym(@|\$| )" <<< "$syms"; then echo "exports $sym"; else echo "::error::$lib does not export $sym"; exit 1; fi
  done
done

R CMD javareconf
rm -rf /work && mkdir -p /work/rJava /work/lib /work/jvmhost
cp -a /src/. /work/rJava/
cd /work/rJava
sh mkdist
R CMD INSTALL --library=/work/lib /work/rJava_*.tar.gz
export R_LIBS=/work/lib

lib="$(Rscript --vanilla -e 'cat(system.file("libs", package="rJava"))')"
# musl's ldd also resolves symbols, and R's symbols come from the executable.
readelf -d "$lib/rJava.so" | grep NEEDED
if readelf -d "$lib/rJava.so" | grep NEEDED | grep -i libjvm; then echo "::error::rJava.so depends on libjvm"; exit 1; fi

Rscript --vanilla tests-integration/jni-abi.R "$RJE_JAVA_HOME_A" "$RJE_JAVA_HOME_B"
cp tests-integration/jvmhost.c /work/jvmhost/
(cd /work/jvmhost && PKG_CPPFLAGS="-I/work/rJava/src" R CMD SHLIB jvmhost.c)
export RJE_JVMHOST=/work/jvmhost/jvmhost.so

# The scenarios of dynamic.yaml that apply to Linux.
run() { echo "::group::$*"; Rscript --vanilla tests-integration/deferred.R "$@"; echo "::endgroup::"; }
for scenario in select retry badinput unload preloaded nonascii fallback laterload hosted decoy; do
  run "$scenario"
done
run hosted explicit
run jengine
run preloaded global
run laterload b
run alias link
run alias spelling
run renamed copy
run renamed hardlink
run renamed symlink
run hosted renamed
run replaced deleted
run replaced replaced
run hosted replaced

echo "::group::JRI host"
Rscript --vanilla tests-integration/jri.R
RJE_JAVA_HOME_A="$RJE_JAVA_HOME_B" RJE_JAVA_HOME_B="$RJE_JAVA_HOME_A" Rscript --vanilla tests-integration/jri.R
echo "::endgroup::"

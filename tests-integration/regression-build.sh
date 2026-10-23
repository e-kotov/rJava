#!/usr/bin/env bash
# Isolated builds for comparisons against master and the reviewed bad head.
set -euo pipefail
root=$PWD
work="$RUNNER_TEMP/rjava-regressions"
if [[ "$RUNNER_OS" == Windows ]]; then work="$(cygpath -u "$work")"; fi
mkdir -p "$work"/{sources,logs,native} "$work/lib"/{master,before,current,javagd}
for variant in master before current; do
  case $variant in
    master) ref=534ff33499641619e3ca3ac7d573d953613d0102 ;;
    before) ref=c5834c8efa6c97239f9f922d5bdedd8e143cf30a ;;
    current) ref=$UPSTREAM_CANDIDATE ;;
  esac
  dir="$work/sources/$variant"
  mkdir -p "$dir"
  git archive "$ref" | tar -x -C "$dir"
  cp -a src/jri/REngine "$dir/src/jri/"
  (cd "$dir" && sh mkdist > "$work/logs/build-$variant.log" 2>&1) || { cat "$work/logs/build-$variant.log"; exit 1; }
  archive="$(ls "$work/sources"/rJava_*.tar.gz)"
  R CMD INSTALL --library="$work/lib/$variant" "$archive" > "$work/logs/install-$variant.log" 2>&1 || { cat "$work/logs/install-$variant.log"; exit 1; }
  rm "$archive"
  echo "BUILT $variant from $ref"
done
if [[ "$RUNNER_OS" == Windows ]]; then
  cp tests-integration/{msvc-modules.c,jvmhost.c} "$work/native/"
  includes="$(cygpath -m "$root/src")"
  (cd "$work/native" && PKG_LIBS=-lversion R CMD SHLIB msvc-modules.c && PKG_CPPFLAGS="-I$includes" R CMD SHLIB jvmhost.c)
  echo "RJE_REGRESSION_HOST=$(cygpath -m "$work/native/jvmhost.dll")" >> "$GITHUB_ENV"
fi

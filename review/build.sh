#!/usr/bin/env bash
# Builds master, the exact candidate and a review variant from pinned SHAs.
set -euo pipefail
root=$PWD
work="$(cygpath -u "$RUNNER_TEMP")/review"
master=534ff33499641619e3ca3ac7d573d953613d0102
candidate=c5834c8efa6c97239f9f922d5bdedd8e143cf30a
mkdir -p "$work"/{sources,lib,logs,native}
for variant in master candidate fix; do
  ref=$candidate; [[ $variant == master ]] && ref=$master
  dir="$work/sources/$variant"; mkdir -p "$dir" "$work/lib/$variant"
  git archive "$ref" | tar -x -C "$dir"
  cp -a src/jri/REngine "$dir/src/jri/"
  if [[ $variant == fix ]]; then (cd "$dir" && git apply "$root/review/fix-msvc.patch"); fi
  (cd "$dir" && sh mkdist > "$work/logs/build-$variant.log" 2>&1) || { cat "$work/logs/build-$variant.log"; exit 1; }
  archive="$(ls "$work/sources"/rJava_*.tar.gz)"
  R CMD INSTALL --library="$(cygpath -m "$work/lib/$variant")" "$archive" > "$work/logs/install-$variant.log" 2>&1 \
    || { cat "$work/logs/install-$variant.log"; exit 1; }
  echo "BUILT $variant from $ref ($(git rev-parse "$ref"))"
  rm "$archive"
done
cp review/modules.c "$work/native/"
(cd "$work/native" && PKG_LIBS=-lversion R CMD SHLIB modules.c)

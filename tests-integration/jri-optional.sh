#!/usr/bin/env bash
set -euo pipefail
archive="$RUNNER_TEMP/$(basename "$(ls ../rJava_*.tar.gz)")"
work="$RUNNER_TEMP/jri-optional"
mkdir -p "$work"/{strict,ignore,skip}
# A real javac failure must stop the normal install.
if env IGNORE= JRI=1 JRI_JFLAGS=--rjava-intentional-invalid-option R CMD INSTALL \
    --library="$work/strict" "$archive" > "$work/strict.log" 2>&1; then
  echo '::error::JRI failure unexpectedly succeeded'; exit 1
fi
if command -v rg >/dev/null; then
  rg -q -- 'rjava-intentional-invalid-option' "$work/strict.log"
else
  grep -q -- 'rjava-intentional-invalid-option' "$work/strict.log"
fi
for mode in ignore skip; do
  if [[ "$mode" == ignore ]]; then
    env IGNORE=1 JRI=1 JRI_JFLAGS=--rjava-intentional-invalid-option R CMD INSTALL \
      --library="$work/$mode" "$archive" > "$work/$mode.log" 2>&1
  else
    env IGNORE= JRI=0 R CMD INSTALL --library="$work/$mode" "$archive" > "$work/$mode.log" 2>&1
  fi
  env R_LIBS="$work/$mode" JAVA_HOME="$RJE_JAVA_HOME_B" Rscript --vanilla -e \
    'library(rJava); stopifnot(!file.exists(system.file("jri", "JRI.jar", package="rJava"))); .jinit(); stopifnot(.jcall("java/lang/System", "S", "getProperty", "java.version") != ""); cat("PASS rJava without JRI\n")'
done

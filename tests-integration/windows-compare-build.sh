#!/usr/bin/env bash
# Build controlled variants from pinned commits, never modifying PR #2.
set -euo pipefail
root=$PWD
work="$(cygpath -u "$RUNNER_TEMP")/rjava-windows-comparison"
candidate=fdbe195dc8e9a480345197eede0d0131a912eac5
master=534ff33499641619e3ca3ac7d573d953613d0102
enhanced=cd6bbe5ef94172ac85e9c44ae8930d0ce4bf40b2
mkdir -p "$work"/{sources,lib,logs,native,classes}
for ref in "$candidate" "$master" "$enhanced" "$UPSTREAM_CANDIDATE"; do git cat-file -e "$ref^{commit}"; done
for variant in master candidate msvc current jri; do
  ref=$candidate
  if [[ "$variant" == master ]]; then ref=$master; fi
  if [[ "$variant" == current ]]; then ref=$UPSTREAM_CANDIDATE; fi
  dir="$work/sources/$variant"
  mkdir -p "$dir" "$work/lib/$variant"
  git archive "$ref" | tar -x -C "$dir"
  cp -a src/jri/REngine "$dir/src/jri/"
  (
    cd "$dir"
    python - "$variant" "$root" "$enhanced" <<'PY'
from pathlib import Path
import subprocess, sys
variant, repo, enhanced = sys.argv[1:]
def original(name):
    return subprocess.check_output(['git', '-C', repo, 'show', enhanced+':'+name]).decode()
if variant == 'jri':
    for name in ['configure.win', 'src/jri/Makefile.win', 'src/jri/src/Makefile.all',
                 'src/jri/src/Makefile.win', 'src/jri/src/Rdecl.h',
                 'src/jri/src/Rengine.c', 'src/jri/src/Rinit.c']:
        Path(name).write_text(original(name))
elif variant == 'msvc':
    old = original('src/djni.c')
    start = old.index('/* Keep already loaded runtimes alive;')
    end = old.index('static int load_library(', start)
    p = Path('src/djni.c')
    source = p.read_text()
    marker = 'static int load_library('
    pos = source.index(marker)
    source = source[:pos] + old[start:end] + source[pos:]
    for entry, end_marker in [('int djni_load(', '/* returns: 0 = success, -1 = already loaded, -3'),
                              ('int djni_attach(', 'int djni_unload(')]:
        start = source.index(entry)
        end = source.index(end_marker, start)
        part = source[start:end]
        pos = part.rindex('    return res;')
        part = part[:pos] + '#ifdef _WIN32\n    if (!res) load_bundled_msvc();\n#endif\n' + part[pos:]
        source = source[:start] + part + source[end:]
    p.write_text(source)
if variant == 'current':
    # The main candidate now includes exactly the MSVC-only runtime tested
    # in the necessity experiment. Ignore platform newline conversion.
    current = Path('src/djni.c').read_text()
    tested = (Path.cwd().parent / 'msvc/src/djni.c').read_text()
    if current != tested:
        raise SystemExit('Current candidate differs from the isolated, tested MSVC implementation')
    print('Current candidate djni.c matches the isolated MSVC implementation')
print('BUILD VARIANT', variant)
PY
    # Keep an auditable patch for each enhancement against the candidate.
    if [[ "$variant" == msvc ]]; then
      git -C "$root" show "$candidate:src/djni.c" > "$work/djni-candidate.c"
      diff -u "$work/djni-candidate.c" src/djni.c > "$work/logs/msvc.patch" || [[ $? == 1 ]]
    fi
    sh mkdist > "$work/logs/build-$variant.log" 2>&1 || { cat "$work/logs/build-$variant.log"; exit 1; }
    archive="$(ls "$work/sources"/rJava_*.tar.gz)"
    cp "$archive" "$work/$variant.tar.gz"
    R CMD INSTALL --library="$(cygpath -m "$work/lib/$variant")" "$archive" \
      > "$work/logs/install-$variant.log" 2>&1 || { cat "$work/logs/install-$variant.log"; exit 1; }
    rm "$archive"
  )
done
cp tests-integration/{jvmhost.c,windows-modules.c} "$work/native/"
includes="$(cygpath -m "$root/src")"
(cd "$work/native" && PKG_CPPFLAGS="-I$includes" R CMD SHLIB jvmhost.c && R CMD SHLIB windows-modules.c)
jar="$(cygpath -m "$work/lib/jri/rJava/jri/JRI.jar")"
"$JAVA_HOME/bin/javac" -source 8 -target 8 -cp "$jar" -d "$(cygpath -m "$work/classes")" \
  "$(cygpath -m "$root/tests-integration/WindowsCompareJri.java")"
{
  echo "RJE_COMPARE_ROOT=$(cygpath -m "$work")"
  echo "RJE_COMPARE_R_HOME=$(Rscript --vanilla -e 'cat(R.home())')"
  echo "RJE_COMPARE_RSCRIPT=$(Rscript --vanilla -e 'cat(file.path(R.home("bin"), "Rscript.exe"))')"
  echo "RJE_COMPARE_HOST=$(cygpath -m "$work/native/jvmhost.dll")"
  echo "RJE_COMPARE_MODULES=$(cygpath -m "$work/native/windows-modules.dll")"
  echo "RJE_COMPARE_WORKLOAD=$(cygpath -m "$root/tests-integration/windows-workload.R")"
} >> "$GITHUB_ENV"
# Demonstrate how enabling JRI changes install-failure behavior, once per R.
if [[ "$RJE_TEST_JDK_VERSION" == 21 ]]; then
  for variant in candidate current jri; do
    mkdir -p "$work/lib/invalid-$variant"
    status=0
    env IGNORE= JRI=1 JRI_JFLAGS=--rjava-intentional-invalid-option R CMD INSTALL \
      --library="$(cygpath -m "$work/lib/invalid-$variant")" "$work/$variant.tar.gz" \
      > "$work/logs/jri-invalid-$variant.log" 2>&1 || status=$?
    if [[ "$variant" != jri ]]; then
      [[ "$status" == 0 ]]
    else
      [[ "$status" != 0 ]]
      if command -v rg >/dev/null; then
        rg -F -- 'rjava-intentional-invalid-option' "$work/logs/jri-invalid-$variant.log"
      else
        grep -F -- 'rjava-intentional-invalid-option' "$work/logs/jri-invalid-$variant.log"
      fi
    fi
    echo "JRI intentional compiler failure: $variant exit=$status"
  done
fi

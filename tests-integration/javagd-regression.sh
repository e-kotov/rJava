#!/usr/bin/env bash
set -euo pipefail
work="$RUNNER_TEMP/rjava-regressions"
rows="$work/results.csv"
echo 'os,build,scenario,java_home,exit' > "$rows"
failed=0
for variant in master before current; do
  for scenario in rjava javagd; do
    for home in unset reconf alternate; do
      case $home in
        unset) envs=(env -u JAVA_HOME) ;;
        reconf) envs=(env JAVA_HOME="$(R CMD config JAVA_HOME)") ;;
        alternate) envs=(env JAVA_HOME="$RJE_JAVA_ALTERNATE") ;;
      esac
      log="$work/logs/$variant-$scenario-$home.log"
      status=0
      "${envs[@]}" Rscript --vanilla tests-integration/javagd-regression.R "$work/lib/$variant" "$work/lib/javagd" "$scenario" > "$log" 2>&1 || status=$?
      cat "$log"
      echo "$RUNNER_OS,$variant,$scenario,$home,$status" >> "$rows"
      # The macOS before/unset/JavaGD control must reproduce the reviewed bug.
      if [[ "$RUNNER_OS" == macOS && "$variant" == before && "$scenario" == javagd && "$home" == unset ]]; then
        if [[ "$status" == 0 ]] || ! grep -q 'Another JVM library is already mapped' "$log"; then
          echo '::error::macOS JavaGD negative control did not reproduce'; failed=1
        fi
      elif [[ "$status" != 0 ]] || ! grep -q 'RESULT|PASS' "$log"; then
        echo "::error::$variant $scenario JAVA_HOME=$home failed"; failed=1
      fi
    done
  done
done
cat "$rows" >> "$GITHUB_STEP_SUMMARY"
exit "$failed"

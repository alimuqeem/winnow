#!/bin/zsh
# Quiet xcodebuild wrapper: scripts/xc.sh build | test   (CONFIG=Release for speed tests)
# Prints only errors, warnings from our sources, test results and the verdict.
set -uo pipefail
cd ${0:A:h:h}
action=${1:-build}
log=$(mktemp "${TMPDIR:-/tmp}/winnow-xc.XXXXXX")
xcodebuild -scheme Winnow -configuration ${CONFIG:-Debug} -destination 'platform=macOS' -allowProvisioningUpdates \
  -derivedDataPath build/DerivedData "$action" >"$log" 2>&1
rc=$?
grep -E "^/.*(error|warning):|Test Case .*(passed|failed)|Executed [0-9]+ test|\*\* .* (SUCCEEDED|FAILED) \*\*|error: " "$log" \
  | grep -v "appintentsmetadataprocessor" | sort -u | grep -v "passed"
grep -E "Executed [0-9]+ test" "$log" | tail -1
[[ $rc -ne 0 ]] && echo "full log: $log"
exit $rc

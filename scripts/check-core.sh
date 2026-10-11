#!/bin/zsh
# Works with Command Line Tools only (no Xcode, no SwiftPM):
#   1. builds WinnowCore as a module
#   2. typechecks the app sources against it
#   3. runs a smoke test of the core logic
# The real XCTest suite (Tests/) runs under Xcode: `xcodebuild test -scheme Winnow`.
set -euo pipefail
root=${0:A:h:h}
out=$(mktemp -d "${TMPDIR:-/tmp}/winnow-check.XXXXXX")
core=($root/Sources/WinnowCore/*.swift)

swiftc -parse-as-library -emit-module -emit-library -module-name WinnowCore \
  -emit-module-path "$out/WinnowCore.swiftmodule" -o "$out/libWinnowCore.dylib" "${core[@]}"
echo "✓ WinnowCore builds"

# SwiftUI/Observation macros (@State, @Observable) need Xcode's macro plugins;
# Command Line Tools don't ship them.
if xcodebuild -version >/dev/null 2>&1; then
  swiftc -typecheck -parse-as-library -I "$out" $root/Sources/Winnow/**/*.swift
  echo "✓ app sources typecheck"
else
  echo "– app typecheck skipped (needs Xcode.app for SwiftUI macros)"
fi

swiftc -I "$out" -L "$out" -lWinnowCore -Xlinker -rpath -Xlinker "$out" \
  -o "$out/smoke" "$root/scripts/smoke.swift"
"$out/smoke"

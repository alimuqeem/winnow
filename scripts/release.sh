#!/bin/zsh
# Build a downloadable, ad-hoc signed (not notarised) universal Winnow.app and zip it.
#   scripts/release.sh            -> build/release/Winnow-<version>.zip (+ .sha256)
# Ad-hoc signing needs no Apple account; users approve the app once via
# System Settings › Privacy & Security › Open Anyway (see README).
set -euo pipefail
cd ${0:A:h:h}

# Releases use their own bundle ID (not your local.env one), so a downloaded copy
# and your dev build don't share a Photos permission entry. Afterwards the project
# is regenerated with your local.env so dev builds keep their identity.
trap '[[ -f local.env ]] && scripts/bootstrap.sh >/dev/null' EXIT
WINNOW_TEAM= WINNOW_BUNDLE_PREFIX=io.github.alimuqeem xcodegen generate --quiet

out=build/release
rm -rf "$out" && mkdir -p "$out"
log="$out/xcodebuild.log"
xcodebuild -scheme Winnow -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$out/DerivedData" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  build >"$log" 2>&1 || { grep -E "error:" "$log" | head -20; echo "build failed: $log"; exit 1; }

app="$out/DerivedData/Build/Products/Release/Winnow.app"
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
# Re-sign the whole bundle (framework first) so the ad-hoc signature is consistent.
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"

cp -R "$app" "$out/Winnow.app"
zip="$out/Winnow-$version.zip"
ditto -c -k --keepParent "$out/Winnow.app" "$zip"
shasum -a 256 "$zip" | tee "$zip.sha256"
echo "archs: $(lipo -archs "$out/Winnow.app/Contents/MacOS/Winnow")"
echo "built $zip"

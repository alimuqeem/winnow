#!/bin/zsh
# Generate Winnow.xcodeproj from project.yml with your signing settings.
# Settings come from local.env (copy local.env.example) or the environment.
set -euo pipefail
cd ${0:A:h:h}

[[ -f local.env ]] && { set -a; source local.env; set +a }
if [[ -z "${WINNOW_TEAM:-}" || -z "${WINNOW_BUNDLE_PREFIX:-}" ]]; then
  echo "Set WINNOW_TEAM and WINNOW_BUNDLE_PREFIX: cp local.env.example local.env and edit it." >&2
  exit 1
fi
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Xcode.app is required. Install it, then: sudo xcode-select -s /Applications/Xcode.app" >&2
  exit 1
fi
command -v xcodegen >/dev/null || { echo "Install XcodeGen: brew install xcodegen" >&2; exit 1; }

xcodegen generate
echo "Generated Winnow.xcodeproj (team $WINNOW_TEAM, bundle $WINNOW_BUNDLE_PREFIX.Winnow)."
echo "Build: CONFIG=Release scripts/xc.sh build"

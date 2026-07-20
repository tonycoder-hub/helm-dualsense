#!/usr/bin/env bash

set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
app_root=$(cd "$test_dir/.." && pwd)
plist="$app_root/Resources/Info.plist"
views="$app_root/Sources/Views.swift"
model="$app_root/Sources/AppModel.swift"
build_script="$app_root/scripts/build-and-install.sh"
release_workflow="$app_root/../.github/workflows/release.yml"

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$plist"
}

[[ $(plist_value CFBundleDisplayName) == "GripPilot" ]]
[[ $(plist_value CFBundleName) == "GripPilot" ]]
[[ $(plist_value CFBundleIconFile) == "GripPilot.icns" ]]
[[ $(plist_value CFBundleShortVersionString) == "0.11.1" ]]
[[ $(plist_value CFBundleVersion) == "29" ]]

# These values deliberately stay stable across the visible rebrand so macOS
# keeps the existing Accessibility/Microphone grants and Sparkle identity.
[[ $(plist_value CFBundleIdentifier) == "io.github.tonycoder-hub.helm" ]]
[[ $(plist_value CFBundleExecutable) == "HelmDemo" ]]
[[ $(plist_value HelmLocalUpdateIdentity) == "io.github.tonycoder-hub.helm.local-v1" ]]
grep -Fq 'bundle_name="GripPilot.app"' "$build_script"
grep -Fq 'legacy_bundle_name="Helm Demo.app"' "$build_script"
grep -Fq 'Tests/bundle-path-migration-tests.sh' "$build_script"
grep -Fq "'macos-app/.build/GripPilot.app'" "$release_workflow"

[[ -f "$app_root/Resources/GripPilot-Icon-1024.png" ]]
[[ -f "$app_root/Resources/GripPilot.icns" ]]
grep -Fq 'Resources/GripPilot.icns' "$build_script"
grep -Fq 'Text("GripPilot")' "$views"
if grep -Fq 'Text("Helm")' "$views"; then
    echo "Legacy Helm product label remains in Views.swift" >&2
    exit 1
fi
grep -Fq 'GripPilot 使用辅助功能' "$model"

echo "GripPilot brand identity contract tests passed."

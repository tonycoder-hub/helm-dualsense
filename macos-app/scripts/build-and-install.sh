#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
app_root=$(cd "$script_dir/.." && pwd)
source_dir="$app_root/Sources"
build_dir="$app_root/.build"
vendor_framework=${HELM_SDL3_FRAMEWORK:-"$app_root/.vendor/SDL3.framework"}
bundle_name="Helm Demo.app"
staged_app="$build_dir/$bundle_name"
install_root="$HOME/Applications"
installed_app="$install_root/$bundle_name"
sdk=$(xcrun --show-sdk-path)
architecture=$(uname -m)

if [[ ! -f "$vendor_framework/SDL3" ]]; then
    echo "Missing SDL3.framework at: $vendor_framework" >&2
    exit 2
fi

mkdir -p "$build_dir"
rm -rf "$staged_app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources" "$staged_app/Contents/Frameworks"

xcrun swiftc \
    -swift-version 5 \
    -warnings-as-errors \
    -sdk "$sdk" \
    -target "$architecture-apple-macos14.0" \
    "$source_dir/ControlMath.swift" \
    "$source_dir/ControllerMapping.swift" \
    "$source_dir/AudioInputCatalog.swift" \
    "$source_dir/TextInsertionPolicy.swift" \
    "$source_dir/ExternalFocusHistory.swift" \
    "$app_root/Tests/main.swift" \
    -framework AVFoundation \
    -framework CoreAudio \
    -o "$build_dir/ControlMathTests"
"$build_dir/ControlMathTests"

xcrun clang \
    -std=c11 \
    -Wall \
    -Wextra \
    -Werror \
    -arch "$architecture" \
    -mmacosx-version-min=14.0 \
    -F "$(dirname "$vendor_framework")" \
    -c "$source_dir/HelmBridge.c" \
    -o "$build_dir/HelmBridge.o"

swift_sources=("$source_dir"/*.swift)
xcrun swiftc \
    -swift-version 5 \
    -warnings-as-errors \
    -parse-as-library \
    -O \
    -sdk "$sdk" \
    -target "$architecture-apple-macos14.0" \
    -import-objc-header "$source_dir/HelmBridge.h" \
    "${swift_sources[@]}" \
    "$build_dir/HelmBridge.o" \
    -F "$(dirname "$vendor_framework")" \
    -framework SDL3 \
    -framework AppKit \
    -framework ApplicationServices \
    -framework AVFoundation \
    -framework Carbon \
    -framework CoreAudio \
    -framework CoreGraphics \
    -framework Speech \
    -Xlinker -rpath \
    -Xlinker @executable_path/../Frameworks \
    -o "$staged_app/Contents/MacOS/HelmDemo"

ditto "$vendor_framework" "$staged_app/Contents/Frameworks/SDL3.framework"
ditto "$app_root/Resources/Info.plist" "$staged_app/Contents/Info.plist"
if [[ -f "$vendor_framework/Resources/LICENSE.txt" ]]; then
    ditto "$vendor_framework/Resources/LICENSE.txt" "$staged_app/Contents/Resources/SDL3-LICENSE.txt"
fi

plutil -lint "$staged_app/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$staged_app/Contents/Frameworks/SDL3.framework"
codesign --force --deep --sign - --timestamp=none --identifier io.github.tonycoder-hub.helm "$staged_app"
codesign --verify --deep --strict --verbose=2 "$staged_app"

mkdir -p "$install_root"
install_temp="$install_root/.Helm-Demo-install-$$.app"
previous_temp="$install_root/.Helm-Demo-previous-$$.app"
replacement_started=0
install_verified=0
cleanup_install() {
    rm -rf "$install_temp"
    if [[ "$install_verified" -eq 1 ]]; then
        rm -rf "$previous_temp"
    elif [[ -e "$previous_temp" ]]; then
        rm -rf "$installed_app"
        mv "$previous_temp" "$installed_app"
    elif [[ "$replacement_started" -eq 1 ]]; then
        rm -rf "$installed_app"
    fi
}
trap cleanup_install EXIT
ditto "$staged_app" "$install_temp"

if pgrep -x HelmDemo >/dev/null 2>&1; then
    osascript -e 'tell application id "io.github.tonycoder-hub.helm" to quit' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5; do
        pgrep -x HelmDemo >/dev/null 2>&1 || break
        sleep 1
    done
    if pgrep -x HelmDemo >/dev/null 2>&1; then
        echo "Helm Demo is still running; stop it from the menu bar and retry." >&2
        exit 3
    fi
fi

if [[ -e "$installed_app" ]]; then
    mv "$installed_app" "$previous_temp"
fi
replacement_started=1
mv "$install_temp" "$installed_app"

codesign --verify --deep --strict --verbose=2 "$installed_app"
install_verified=1
rm -rf "$previous_temp"
echo "INSTALLED_APP=$installed_app"
echo "BUNDLE_ID=$(defaults read "$installed_app/Contents/Info.plist" CFBundleIdentifier)"

if [[ ${1:-} == "--launch" ]]; then
    open "$installed_app"
fi

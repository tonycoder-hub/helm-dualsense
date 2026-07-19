#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
source "$script_dir/local-signing.sh"
source "$script_dir/local-install.sh"
app_root=$(cd "$script_dir/.." && pwd)
source_dir="$app_root/Sources"
build_dir="$app_root/.build"
vendor_framework=${HELM_SDL3_FRAMEWORK:-"$app_root/.vendor/SDL3.framework"}
sparkle_framework=${HELM_SPARKLE_FRAMEWORK:-"$app_root/.vendor/Sparkle.framework"}
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
if [[ ! -f "$sparkle_framework/Sparkle" ]]; then
    echo "Missing Sparkle.framework at: $sparkle_framework" >&2
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
    "$source_dir/ContinuousScrollEvent.swift" \
    "$source_dir/DisplaySynchronizedMotion.swift" \
    "$source_dir/PointerEventFactory.swift" \
    "$source_dir/UnicodeKeyboardEventFactory.swift" \
    "$source_dir/ControllerMapping.swift" \
    "$source_dir/AudioInputCatalog.swift" \
    "$source_dir/PermissionDiagnostics.swift" \
    "$source_dir/TextInsertionPolicy.swift" \
    "$source_dir/ExternalFocusHistory.swift" \
    "$source_dir/HapticFeedback.swift" \
    "$source_dir/MappingLayoutPolicy.swift" \
    "$source_dir/SparkleUpdateConfiguration.swift" \
    "$app_root/Tests/main.swift" \
    -framework AVFoundation \
    -framework AppKit \
    -framework CoreAudio \
    -framework CoreGraphics \
    -o "$build_dir/ControlMathTests"
"$build_dir/ControlMathTests"

xcrun swiftc \
    -swift-version 5 \
    -warnings-as-errors \
    -parse-as-library \
    -sdk "$sdk" \
    -target "$architecture-apple-macos14.0" \
    "$source_dir/ControlMath.swift" \
    "$source_dir/InputCadenceDriver.swift" \
    "$app_root/Tests/InputCadenceTests.swift" \
    -o "$build_dir/InputCadenceTests"
"$build_dir/InputCadenceTests"

xcrun swiftc \
    -swift-version 5 \
    -warnings-as-errors \
    -parse-as-library \
    -sdk "$sdk" \
    -target "$architecture-apple-macos14.0" \
    "$source_dir/ControlMath.swift" \
    "$source_dir/InputCadenceDriver.swift" \
    "$app_root/Tests/BackgroundCadenceIntegrationTests.swift" \
    -framework AppKit \
    -o "$build_dir/BackgroundCadenceIntegrationTests"
"$build_dir/BackgroundCadenceIntegrationTests"

xcrun swiftc \
    -swift-version 5 \
    -warnings-as-errors \
    -parse-as-library \
    -sdk "$sdk" \
    -target "$architecture-apple-macos14.0" \
    "$source_dir/ControlMath.swift" \
    "$source_dir/ContinuousScrollEvent.swift" \
    "$source_dir/ControllerMapping.swift" \
    "$source_dir/AudioInputCatalog.swift" \
    "$source_dir/InputCadenceDriver.swift" \
    "$source_dir/MotionSamplingDriver.swift" \
    "$app_root/Tests/MotionSamplingDriverTests.swift" \
    -framework AppKit \
    -framework AVFoundation \
    -framework CoreAudio \
    -framework CoreGraphics \
    -o "$build_dir/MotionSamplingDriverTests"
"$build_dir/MotionSamplingDriverTests"

bash "$app_root/Tests/local-update-identity-tests.sh"
bash "$app_root/Tests/in-place-install-tests.sh"

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

xcrun clang \
    -std=c11 \
    -Wall \
    -Wextra \
    -Werror \
    -arch "$architecture" \
    -mmacosx-version-min=14.0 \
    -I "$source_dir" \
    -F "$(dirname "$vendor_framework")" \
    "$build_dir/HelmBridge.o" \
    "$app_root/Tests/HelmBridgeAnalogIntegrationTests.c" \
    -framework SDL3 \
    -framework Carbon \
    -o "$build_dir/HelmBridgeAnalogIntegrationTests"
DYLD_FRAMEWORK_PATH="$(dirname "$vendor_framework")" \
    "$build_dir/HelmBridgeAnalogIntegrationTests"

xcrun clang \
    -std=c11 \
    -Wall \
    -Wextra \
    -Werror \
    -arch "$architecture" \
    -mmacosx-version-min=14.0 \
    -I "$source_dir" \
    -F "$(dirname "$vendor_framework")" \
    "$build_dir/HelmBridge.o" \
    "$app_root/Tests/HelmBridgeConcurrencyIntegrationTests.c" \
    -framework SDL3 \
    -framework Carbon \
    -o "$build_dir/HelmBridgeConcurrencyIntegrationTests"
DYLD_FRAMEWORK_PATH="$(dirname "$vendor_framework")" \
    "$build_dir/HelmBridgeConcurrencyIntegrationTests"

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
    -framework Sparkle \
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
ditto "$sparkle_framework" "$staged_app/Contents/Frameworks/Sparkle.framework"
ditto "$app_root/Resources/Info.plist" "$staged_app/Contents/Info.plist"
if [[ -f "$vendor_framework/Resources/LICENSE.txt" ]]; then
    ditto "$vendor_framework/Resources/LICENSE.txt" "$staged_app/Contents/Resources/SDL3-LICENSE.txt"
fi
if [[ -f "$app_root/.vendor/Sparkle-LICENSE.txt" ]]; then
    ditto "$app_root/.vendor/Sparkle-LICENSE.txt" \
        "$staged_app/Contents/Resources/Sparkle-LICENSE.txt"
fi

plutil -lint "$staged_app/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$staged_app/Contents/Frameworks/SDL3.framework"
codesign --force --deep --sign - --timestamp=none \
    "$staged_app/Contents/Frameworks/Sparkle.framework"
helm_sign_local_app "$staged_app"

mkdir -p "$install_root"

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

helm_install_app_contents "$staged_app" "$installed_app" helm_verify_local_app_identity
echo "INSTALLED_APP=$installed_app"
echo "BUNDLE_ID=$(defaults read "$installed_app/Contents/Info.plist" CFBundleIdentifier)"

if [[ ${1:-} == "--launch" ]]; then
    open "$installed_app"
fi

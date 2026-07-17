#!/usr/bin/env bash

set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
source "$test_dir/../scripts/local-signing.sh"

fixture_dir=$(mktemp -d /tmp/helm-local-identity.XXXXXX)
trap 'rm -rf "$fixture_dir"' EXIT

make_fixture() {
    local app=$1
    local build_number=$2
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
    cat >"$fixture_dir/main-$build_number.c" <<SOURCE
int main(void) { return $build_number; }
SOURCE
    xcrun clang "$fixture_dir/main-$build_number.c" -o "$app/Contents/MacOS/HelmDemo"
    xcrun clang -dynamiclib "$fixture_dir/main-$build_number.c" \
        -o "$app/Contents/Frameworks/Fixture.dylib"
    codesign --force --sign - --timestamp=none "$app/Contents/Frameworks/Fixture.dylib"
    cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>HelmDemo</string>
  <key>CFBundleIdentifier</key><string>$HELM_LOCAL_BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>HelmLocalUpdateIdentity</key><string>$HELM_LOCAL_UPDATE_IDENTITY</string>
</dict></plist>
PLIST
}

first="$fixture_dir/first.app"
second="$fixture_dir/second.app"
make_fixture "$first" 1
make_fixture "$second" 2

helm_sign_local_app "$first"
helm_sign_local_app "$second"
helm_verify_local_app_identity "$first"
helm_verify_local_app_identity "$second"

first_requirement=$(helm_local_app_requirement "$first")
second_requirement=$(helm_local_app_requirement "$second")
[[ "$first_requirement" == "$second_requirement" ]]
grep -Fq "identifier \"$HELM_LOCAL_BUNDLE_ID\"" <<<"$first_requirement"
grep -Fq "info[HelmLocalUpdateIdentity] = \"$HELM_LOCAL_UPDATE_IDENTITY\"" \
    <<<"$first_requirement"

first_cdhash=$(codesign -dvv "$first" 2>&1 | sed -n 's/^CDHash=//p')
second_cdhash=$(codesign -dvv "$second" 2>&1 | sed -n 's/^CDHash=//p')
[[ -n "$first_cdhash" && -n "$second_cdhash" && "$first_cdhash" != "$second_cdhash" ]]

echo "LOCAL_UPDATE_IDENTITY_TESTS=PASS"

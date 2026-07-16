#!/usr/bin/env bash

set -uo pipefail

usage() {
    cat <<'EOF'
Usage: verify-release-artifact.sh APP [ZIP] [APPCAST] [PREVIOUS_SIGNED_APPCAST]

Fail-closed verification for a final Helm.app, distribution ZIP, and Sparkle
appcast after Developer ID signing, hardened runtime, notarization, and
stapling. It verifies the exact certificate/team, embedded dependency linkage,
Sparkle archive and feed signatures, and monotonic build version.

Environment:
  HELM_EXPECTED_TEAM_ID
  HELM_DEVELOPER_CERT_SHA256
  HELM_EXPECTED_UPDATE_URL
  HELM_RELEASE_ZIP_SHA256
  HELM_RELEASE_SOURCE_COMMIT
  HELM_SPARKLE_ARCHIVE
  HELM_SDL_ARCHIVE
  HELM_SPARKLE_KEY_ACCOUNT
  HELM_PREVIOUS_SIGNED_APPCAST

Tracked trust anchor:
  macos-app/Release/PreviousAppcast.sha256
EOF
}

if [[ ${1:-} == "--help" || ${1:-} == "-h" ]]; then
    usage
    exit 0
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
project_root=$(cd "$script_dir/../.." && pwd)
source "$script_dir/release-lib.sh"

app=${1:-}
archive=${2:-${HELM_RELEASE_ZIP:-}}
appcast=${3:-${HELM_RELEASE_APPCAST:-}}
previous_appcast=${4:-${HELM_PREVIOUS_SIGNED_APPCAST:-}}
expected_team=${HELM_EXPECTED_TEAM_ID:-}
expected_certificate=${HELM_DEVELOPER_CERT_SHA256:-}
expected_update_url=${HELM_EXPECTED_UPDATE_URL:-}
expected_archive_hash=${HELM_RELEASE_ZIP_SHA256:-}
release_source_commit=${HELM_RELEASE_SOURCE_COMMIT:-}
sparkle_archive=${HELM_SPARKLE_ARCHIVE:-}
sdl_archive=${HELM_SDL_ARCHIVE:-}
sparkle_account=${HELM_SPARKLE_KEY_ACCOUNT:-}
blocked=0
work=$(mktemp -d /tmp/helm-release-verification.XXXXXX 2>/dev/null || true)
sparkle_extract=""
sdl_mount=""
sdl_mounted=false

if [[ -z $work || ! -d $work ]]; then
    printf 'RELEASE_ARTIFACT=BLOCKED reason=temporary-workspace-unavailable\n'
    exit 2
fi

cleanup() {
    local original_status=${1:-0}
    local cleanup_failed=false

    if [[ ${HELM_TREE_COMPARISON_CLEANUP_FAILED:-false} == true ]]; then
        cleanup_failed=true
    fi
    if [[ $sdl_mounted == true ]]; then
        if helm_unmount_dmg "$sdl_mount"; then
            sdl_mounted=false
        else
            cleanup_failed=true
        fi
    fi
    if [[ $sdl_mounted == false && -n $work && -d $work ]] \
        && ! /bin/rm -rf -- "$work"; then
        cleanup_failed=true
    fi
    trap - EXIT
    if [[ $cleanup_failed == true ]]; then
        printf 'RELEASE_CLEANUP=BLOCKED reason=temporary-input-cleanup-failed\n' >&2
        exit 3
    fi
    exit "$original_status"
}
trap 'cleanup $?' EXIT

pass_gate() {
    printf 'GATE %s PASS %s\n' "$1" "$2"
}

block_gate() {
    printf 'GATE %s BLOCKED %s\n' "$1" "$2"
    blocked=$((blocked + 1))
}

contents="$app/Contents"
plist="$contents/Info.plist"
app_name=$(basename "$app" 2>/dev/null || true)
product_name=$(helm_bundle_value "$plist" CFBundleName || true)
display_name=$(helm_bundle_value "$plist" CFBundleDisplayName || true)
executable_name=$(helm_bundle_value "$plist" CFBundleExecutable || true)
bundle_id=$(helm_bundle_value "$plist" CFBundleIdentifier || true)
version=$(helm_bundle_value "$plist" CFBundleShortVersionString || true)
build=$(helm_bundle_value "$plist" CFBundleVersion || true)
main_executable="$contents/MacOS/$executable_name"

if [[ -d $app && $app_name == "Helm.app" && $product_name == "Helm" \
    && $display_name == "Helm" && $executable_name == "Helm" \
    && $bundle_id == "io.github.tonycoder-hub.helm" \
    && $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $build =~ ^[1-9][0-9]*$ ]]; then
    pass_gate product_name "formal product name, identifier, and versions are exact"
else
    block_gate product_name "artifact must be a release-shaped Helm.app"
fi

signature_info=""
if [[ -d $app ]]; then
    signature_info=$(codesign -dv --verbose=4 "$app" 2>&1 || true)
fi
certificate_matches=false
if [[ -d $app ]] && helm_valid_sha256 "$expected_certificate"; then
    if codesign -d --extract-certificates="$work/leaf" "$app" >/dev/null 2>&1 \
        && helm_sha256_matches "$work/leaf0" "$expected_certificate"; then
        certificate_matches=true
    fi
fi
if [[ -d $app ]] \
    && helm_valid_team_id "$expected_team" \
    && codesign --verify --deep --strict --verbose=2 "$app" >/dev/null 2>&1 \
    && grep -Fq "Authority=Developer ID Application:" <<<"$signature_info" \
    && grep -Fq "TeamIdentifier=$expected_team" <<<"$signature_info" \
    && [[ $certificate_matches == true ]]; then
    pass_gate codesign "the exact expected Developer ID certificate and Team ID sign the app"
else
    block_gate codesign "verify the strict signature against the expected Developer ID certificate and Team ID"
fi

if grep -Eq '^flags=.*\(.*runtime.*\)' <<<"$signature_info" \
    && grep -Eq '^Timestamp=' <<<"$signature_info"; then
    pass_gate hardened_runtime "hardened runtime and secure timestamp are present"
else
    block_gate hardened_runtime "the final app must use hardened runtime and a secure timestamp"
fi

signed_entitlements=""
if [[ -d $app ]]; then
    signed_entitlements="$work/signed-entitlements.plist"
    codesign -d --entitlements :- "$app" >"$signed_entitlements" 2>/dev/null || true
fi
if helm_entitlements_are_exact "$signed_entitlements"; then
    pass_gate entitlements_exact "signed app entitlements exactly match the release allowlist"
else
    block_gate entitlements_exact "signed app contains missing or additional entitlements"
fi

frameworks="$contents/Frameworks"
sdl_framework="$frameworks/SDL3.framework"
sparkle_framework="$frameworks/Sparkle.framework"
nested_ok=true
nested_index=0
expected_macho_inventory=$'MacOS/Helm\nFrameworks/SDL3.framework/Versions/A/SDL3\nFrameworks/Sparkle.framework/Versions/B/Autoupdate\nFrameworks/Sparkle.framework/Versions/B/Sparkle\nFrameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater\nFrameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader\nFrameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer'
helm_macho_inventory_matches "$contents" "$expected_macho_inventory" \
    || nested_ok=false
for code in "$sdl_framework" "$sparkle_framework" \
    "$sparkle_framework/Versions/B/Autoupdate" \
    "$sparkle_framework/Versions/B/Updater.app" \
    "$sparkle_framework/Versions/B/XPCServices/Downloader.xpc" \
    "$sparkle_framework/Versions/B/XPCServices/Installer.xpc"; do
    if [[ ! -e $code ]] || ! codesign --verify --deep --strict "$code" >/dev/null 2>&1; then
        nested_ok=false
        continue
    fi
    nested_info=$(codesign -dv --verbose=4 "$code" 2>&1 || true)
    nested_certificate="$work/nested-certificate-$nested_index"
    nested_entitlements="$work/nested-entitlements-$nested_index.plist"
    grep -Fq "Authority=Developer ID Application:" <<<"$nested_info" || nested_ok=false
    grep -Fq "TeamIdentifier=$expected_team" <<<"$nested_info" || nested_ok=false
    grep -Eq '^flags=.*\(.*runtime.*\)' <<<"$nested_info" || nested_ok=false
    grep -Eq '^Timestamp=' <<<"$nested_info" || nested_ok=false
    if ! codesign -d --extract-certificates="$nested_certificate" \
        "$code" >/dev/null 2>&1 \
        || ! helm_sha256_matches "${nested_certificate}0" "$expected_certificate"; then
        nested_ok=false
    fi
    if ! codesign -d --entitlements :- \
        "$code" >"$nested_entitlements" 2>/dev/null; then
        nested_ok=false
    elif [[ -s $nested_entitlements ]] \
        && ! helm_entitlements_are_empty "$nested_entitlements"; then
        nested_ok=false
    fi
    nested_index=$((nested_index + 1))
done
if [[ -f $main_executable ]] \
    && [[ $(lipo -archs "$main_executable" 2>/dev/null) == "arm64" ]] \
    && [[ $nested_ok == true ]]; then
    pass_gate nested_code "arm64 executable and every nested code object use the exact certificate, runtime, and empty entitlement policy"
else
    block_gate nested_code "verify every nested framework/helper against the exact certificate, runtime, and empty entitlement policy"
fi

if [[ -d $app ]] \
    && xcrun stapler validate "$app" >/dev/null 2>&1 \
    && spctl --assess --type execute --verbose=4 "$app" >/dev/null 2>&1; then
    pass_gate stapled_ticket "stapled notarization ticket and Gatekeeper assessment are valid"
else
    block_gate stapled_ticket "the final app must have a valid stapled notarization ticket"
fi

pinned_version=$(tr -d '[:space:]' <"$project_root/macos-app/ThirdParty/Sparkle.version" 2>/dev/null || true)
pinned_hash=$(tr -d '[:space:]' <"$project_root/macos-app/ThirdParty/Sparkle.sha256" 2>/dev/null || true)
embedded_version=$(helm_bundle_value "$sparkle_framework/Versions/B/Resources/Info.plist" CFBundleShortVersionString || true)
feed_url=$(helm_bundle_value "$plist" SUFeedURL || true)
public_key=$(helm_bundle_value "$plist" SUPublicEDKey || true)
signed_feed=$(helm_bundle_value "$plist" SURequireSignedFeed || true)
automatic_checks=$(helm_bundle_value "$plist" SUEnableAutomaticChecks || true)
linked_frameworks=$(otool -L "$main_executable" 2>/dev/null || true)
update_urls_ok=false
if helm_valid_https_url "$feed_url" \
    && helm_valid_https_url "$expected_update_url"; then
    update_urls_ok=true
    pass_gate update_urls "embedded feed and expected enclosure use canonical credential-free HTTPS URLs"
else
    block_gate update_urls "require canonical credential-free HTTPS feed and enclosure URLs"
fi

pinned_sdl_version=$(tr -d '[:space:]' \
    <"$project_root/macos-app/ThirdParty/SDL.version" 2>/dev/null || true)
pinned_sdl_hash=$(tr -d '[:space:]' \
    <"$project_root/macos-app/ThirdParty/SDL.sha256" 2>/dev/null || true)
embedded_sdl_version=$(helm_bundle_value \
    "$sdl_framework/Versions/A/Resources/Info.plist" \
    CFBundleShortVersionString || true)
sdl_archive_snapshot="$work/SDL3.dmg"
sdl_source_framework=""
sdl_content_ok=false
if helm_snapshot_regular_file "$sdl_archive" "$sdl_archive_snapshot" \
    && helm_sha256_matches "$sdl_archive_snapshot" "$pinned_sdl_hash"; then
    sdl_mount="$work/sdl-mount"
    mkdir -p "$sdl_mount"
    if helm_mount_readonly_dmg "$sdl_archive_snapshot" "$sdl_mount"; then
        sdl_mounted=true
        sdl_source_framework="$sdl_mount/SDL3.xcframework/macos-arm64_x86_64/SDL3.framework"
        if [[ $pinned_sdl_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ \
            && $embedded_sdl_version == "$pinned_sdl_version" \
            && -d $sdl_source_framework ]] \
            && codesign --verify --deep --strict \
                "$sdl_source_framework" >/dev/null 2>&1 \
            && helm_trees_match_without_signatures \
                "$sdl_source_framework" "$sdl_framework"; then
            sdl_content_ok=true
        fi
    fi
fi
if [[ $sdl_content_ok == true ]]; then
    pass_gate sdl_embedded "embedded SDL content matches the hash-pinned official DMG after signature normalization"
else
    block_gate sdl_embedded "bind embedded SDL content to the exact hash-pinned official DMG"
fi

sparkle_content_ok=false
sparkle_archive_snapshot="$work/Sparkle.tar.xz"
if helm_snapshot_regular_file "$sparkle_archive" "$sparkle_archive_snapshot" \
    && helm_sha256_matches "$sparkle_archive_snapshot" "$pinned_hash"; then
    sparkle_extract="$work/sparkle-official"
    mkdir -p "$sparkle_extract"
    if tar -xf "$sparkle_archive_snapshot" -C "$sparkle_extract" >/dev/null 2>&1 \
        && helm_trees_match_without_signatures \
            "$sparkle_extract/Sparkle.framework" "$sparkle_framework"; then
        sparkle_content_ok=true
    fi
fi
if [[ $pinned_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ \
    && $embedded_version == "$pinned_version" \
    && $sparkle_content_ok == true \
    && -n $public_key && $signed_feed == "true" \
    && $automatic_checks == "false" \
    && $linked_frameworks == *"Sparkle.framework"* \
    && $linked_frameworks == *"SDL3.framework"* \
    && $update_urls_ok == true ]]; then
    pass_gate sparkle_embedded "the final Sparkle content matches the pinned archive after signature normalization and signed HTTPS updates are configured"
else
    block_gate sparkle_embedded "bind final Sparkle content to the pinned archive and configure signed HTTPS updates"
fi

archive_ok=false
if [[ -f $archive ]] \
    && helm_sha256_matches "$archive" "$expected_archive_hash" \
    && helm_zip_entries_are_scoped "$archive" Helm.app; then
    expanded="$work/expanded"
    mkdir -p "$expanded"
    if ditto -x -k "$archive" "$expanded" >/dev/null 2>&1 \
        && [[ -d $expanded/Helm.app ]] \
        && [[ ! -L $expanded/Helm.app ]] \
        && [[ $(find "$expanded" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d '[:space:]') == "1" ]] \
        && helm_tree_symlinks_are_internal "$expanded/Helm.app" \
        && codesign --verify --deep --strict "$expanded/Helm.app" >/dev/null 2>&1 \
        && xcrun stapler validate "$expanded/Helm.app" >/dev/null 2>&1; then
        original_cdhash=$(sed -n 's/^CDHash=//p' <<<"$signature_info")
        expanded_info=$(codesign -dv --verbose=4 "$expanded/Helm.app" 2>&1 || true)
        expanded_cdhash=$(sed -n 's/^CDHash=//p' <<<"$expanded_info")
        [[ -n $original_cdhash && $original_cdhash == "$expanded_cdhash" ]] && archive_ok=true
    fi
fi
if [[ $archive_ok == true ]]; then
    pass_gate archive_integrity "ZIP has one scoped app, internal symlinks, a matching checksum, ticket, and CodeDirectory"
else
    block_gate archive_integrity "require exactly one safe Helm.app payload and verify its checksum, signature, and ticket"
fi

enclosure_signature=""
enclosure_url=""
enclosure_length=""
enclosure_version=""
current_enclosure_count=""
sparkle_namespace='http://www.andymatuschak.org/xml-namespaces/sparkle'
enclosure_xpath="//*[local-name()='enclosure' and namespace-uri()='']"
if [[ -f $appcast && $build =~ ^[1-9][0-9]*$ ]]; then
    current_enclosure_count=$(xmllint --nonet --xpath \
        "count($enclosure_xpath[@*[local-name()='version' and namespace-uri()='$sparkle_namespace']='$build'])" \
        "$appcast" 2>/dev/null || true)
    enclosure_signature=$(xmllint --nonet --xpath \
        "string(($enclosure_xpath[@*[local-name()='version' and namespace-uri()='$sparkle_namespace']='$build'])[1]/@*[local-name()='edSignature' and namespace-uri()='$sparkle_namespace'])" \
        "$appcast" 2>/dev/null || true)
    enclosure_url=$(xmllint --nonet --xpath \
        "string(($enclosure_xpath[@*[local-name()='version' and namespace-uri()='$sparkle_namespace']='$build'])[1]/@url)" \
        "$appcast" 2>/dev/null || true)
    enclosure_length=$(xmllint --nonet --xpath \
        "string(($enclosure_xpath[@*[local-name()='version' and namespace-uri()='$sparkle_namespace']='$build'])[1]/@length)" \
        "$appcast" 2>/dev/null || true)
    enclosure_version=$(xmllint --nonet --xpath \
        "string(($enclosure_xpath[@*[local-name()='version' and namespace-uri()='$sparkle_namespace']='$build'])[1]/@*[local-name()='version' and namespace-uri()='$sparkle_namespace'])" \
        "$appcast" 2>/dev/null || true)
fi
sign_update=""
generate_keys=""
if [[ $sparkle_content_ok == true ]]; then
    sign_update="$sparkle_extract/bin/sign_update"
    generate_keys="$sparkle_extract/bin/generate_keys"
fi
keychain_public=""
if [[ -x $generate_keys && -n $sparkle_account ]]; then
    keychain_public=$($generate_keys --account "$sparkle_account" -p 2>/dev/null | tr -d '[:space:]' || true)
fi
archive_length=""
if [[ -f $archive ]]; then
    archive_length=$(stat -f %z "$archive" 2>/dev/null || true)
fi
update_signature_ok=false
if [[ -x $sign_update && -n $sparkle_account && -n $enclosure_signature \
    && $current_enclosure_count == "1" \
    && $enclosure_url == "$expected_update_url" \
    && $enclosure_length == "$archive_length" \
    && $keychain_public == "$public_key" \
    && $update_urls_ok == true ]] \
    && helm_appcast_has_only_canonical_sparkle_attributes "$appcast"; then
    if "$sign_update" --account "$sparkle_account" --verify \
        "$archive" "$enclosure_signature" >/dev/null 2>&1 \
        && "$sign_update" --account "$sparkle_account" --verify \
        "$appcast" >/dev/null 2>&1; then
        update_signature_ok=true
    fi
fi
if [[ $update_signature_ok == true ]]; then
    pass_gate update_signature "archive and signed appcast verify with the same Keychain key embedded in Helm"
else
    block_gate update_signature "cryptographically verify the archive and appcast against Helm's embedded Sparkle public key"
fi

previous_appcast_signature_ok=false
release_source_exact=false
if helm_release_source_is_exact "$project_root" "$release_source_commit"; then
    release_source_exact=true
fi
history_anchor=$(helm_tracked_regular_file_value \
    "$project_root" "$release_source_commit" \
    macos-app/Release/PreviousAppcast.sha256 2>/dev/null \
    | tr -d '[:space:]' || true)
previous_appcast_is_anchored=false
if helm_sha256_matches "$previous_appcast" "$history_anchor"; then
    previous_appcast_is_anchored=true
fi
if [[ $previous_appcast_is_anchored == true \
    && -x $sign_update && -n $sparkle_account && -f $previous_appcast ]] \
    && helm_appcast_has_only_canonical_sparkle_attributes "$previous_appcast" \
    && "$sign_update" --account "$sparkle_account" --verify \
        "$previous_appcast" >/dev/null 2>&1; then
    previous_appcast_signature_ok=true
fi
previous_max_build=$(helm_appcast_max_build "$previous_appcast" 2>/dev/null || true)
current_max_build=$(helm_appcast_max_build "$appcast" 2>/dev/null || true)
if [[ $previous_appcast_signature_ok == true \
    && $previous_appcast_is_anchored == true \
    && $release_source_exact == true \
    && $build =~ ^[1-9][0-9]*$ \
    && $previous_max_build =~ ^(0|[1-9][0-9]*)$ \
    && $enclosure_version == "$build" \
    && $current_enclosure_count == "1" \
    && $current_max_build == "$build" ]] \
    && helm_decimal_gt "$build" "$previous_max_build"; then
    pass_gate version_monotonic "build exceeds the maximum from the reviewed-hash-anchored, same-key verified prior appcast"
else
    block_gate version_monotonic "require the reviewed prior-appcast hash anchor, same-key verification, and one strictly higher current maximum"
fi

if ((blocked > 0)); then
    printf 'RELEASE_ARTIFACT=BLOCKED blocked_gates=%d\n' "$blocked"
    exit 2
fi

printf 'RELEASE_ARTIFACT=PASS\n'

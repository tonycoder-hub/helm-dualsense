#!/usr/bin/env bash

set -uo pipefail

usage() {
    cat <<'EOF'
Usage: release-preflight.sh

Read-only, fail-closed source and credential checks for a formal Helm release.
This is not final-artifact verification; run verify-release-artifact.sh after
building, signing, notarization, stapling, and generating the Sparkle appcast.
No credential or fingerprint value is printed.

Environment:
  HELM_EXPECTED_TEAM_ID          Ten-character Apple Developer Team ID.
  HELM_DEVELOPER_IDENTITY_SHA1  Exact Keychain codesigning identity selector.
  HELM_DEVELOPER_CERT_SHA256    Exact Developer ID leaf-certificate fingerprint.
  HELM_RELEASE_SOURCE_COMMIT   Full reviewed Git commit; must remain clean HEAD.
  HELM_NOTARY_PROFILE           notarytool Keychain profile name.
  HELM_NOTARY_TEAM_ID           Team ID used when that profile was stored.
  HELM_SPARKLE_ARCHIVE          Official pinned Sparkle distribution archive.
  HELM_SDL_ARCHIVE              Official pinned SDL3 macOS distribution DMG.

Tracked trust anchor:
  macos-app/Release/PreviousAppcast.sha256
EOF
}

if [[ ${1:-} == "--help" || ${1:-} == "-h" ]]; then
    usage
    exit 0
fi

if [[ $# -ne 0 ]]; then
    usage >&2
    exit 64
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
project_root=$(cd "$script_dir/../.." && pwd)
source "$script_dir/release-lib.sh"

plist="$project_root/macos-app/Resources/Info.plist"
blocked=0
sparkle_extract=""
release_inputs=$(mktemp -d /tmp/helm-release-inputs.XXXXXX 2>/dev/null || true)
sdl_mount=""
sdl_mounted=false

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
    if [[ $sdl_mounted == false && -n $sdl_mount && -d $sdl_mount ]] \
        && ! /bin/rmdir "$sdl_mount" >/dev/null 2>&1; then
        cleanup_failed=true
    fi
    if [[ -n $sparkle_extract && -d $sparkle_extract ]] \
        && ! /bin/rm -rf -- "$sparkle_extract"; then
        cleanup_failed=true
    fi
    if [[ -n $release_inputs && -d $release_inputs ]] \
        && ! /bin/rm -rf -- "$release_inputs"; then
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

if git -C "$project_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [[ -z $(git -C "$project_root" status --porcelain --untracked-files=all) ]]; then
        pass_gate git_clean "working tree is clean"
    else
        block_gate git_clean "commit or remove all working-tree changes"
    fi
else
    block_gate git_clean "project is not a Git working tree"
fi

release_source_commit=${HELM_RELEASE_SOURCE_COMMIT:-}
if helm_release_source_is_exact "$project_root" "$release_source_commit"; then
    pass_gate release_source_commit "the clean checkout is the exact reviewed source commit"
else
    block_gate release_source_commit "set the full reviewed Git commit and keep it as a clean unchanged HEAD"
fi

product_name=$(helm_bundle_value "$plist" CFBundleName || true)
display_name=$(helm_bundle_value "$plist" CFBundleDisplayName || true)
executable_name=$(helm_bundle_value "$plist" CFBundleExecutable || true)
if [[ $product_name == "Helm" && $display_name == "Helm" && $executable_name == "Helm" ]]; then
    pass_gate formal_product_name "bundle and executable names are Helm"
else
    block_gate formal_product_name "formal releases must use Helm.app with executable Helm"
fi

bundle_id=$(helm_bundle_value "$plist" CFBundleIdentifier || true)
version=$(helm_bundle_value "$plist" CFBundleShortVersionString || true)
build=$(helm_bundle_value "$plist" CFBundleVersion || true)
if [[ $bundle_id == "io.github.tonycoder-hub.helm" && $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $build =~ ^[1-9][0-9]*$ ]]; then
    pass_gate bundle_metadata "bundle identifier and versions are release-shaped"
else
    block_gate bundle_metadata "bundle identifier, semantic version, or build number is invalid"
fi

expected_team=${HELM_EXPECTED_TEAM_ID:-}
identity_sha1=${HELM_DEVELOPER_IDENTITY_SHA1:-}
certificate_sha256=${HELM_DEVELOPER_CERT_SHA256:-}
identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
certificates=""
if helm_valid_team_id "$expected_team"; then
    certificates=$(security find-certificate -a -Z -c "$expected_team" 2>/dev/null || true)
fi
if helm_valid_team_id "$expected_team" \
    && helm_valid_identity_sha1 "$identity_sha1" \
    && helm_valid_sha256 "$certificate_sha256" \
    && helm_identity_record_matches "$identities" "$identity_sha1" "$expected_team" \
    && helm_certificate_record_matches \
        "$certificates" "$identity_sha1" "$certificate_sha256" "$expected_team"; then
    pass_gate signing_identity "the expected Team ID and exact Developer ID certificate are available"
else
    block_gate signing_identity "configure the expected Team ID and exact Developer ID identity/certificate fingerprints"
fi

if xcrun --find notarytool >/dev/null 2>&1 && xcrun --find stapler >/dev/null 2>&1; then
    pass_gate notarization_tools "notarytool and stapler are available"
else
    block_gate notarization_tools "install Xcode command-line notarization tools"
fi

if [[ -z ${HELM_NOTARY_PROFILE:-} ]] \
    || ! helm_valid_team_id "${HELM_NOTARY_TEAM_ID:-}" \
    || [[ ${HELM_NOTARY_TEAM_ID:-} != "$expected_team" ]]; then
    block_gate notary_profile "configure a notarytool profile explicitly bound to the expected Team ID"
elif xcrun notarytool history --keychain-profile "$HELM_NOTARY_PROFILE" --output-format json >/dev/null 2>&1; then
    pass_gate notary_profile "notarytool authenticated the profile declared for the expected Team ID"
else
    block_gate notary_profile "the configured keychain profile could not authenticate"
fi

feed_url=$(helm_bundle_value "$plist" SUFeedURL || true)
public_key=$(helm_bundle_value "$plist" SUPublicEDKey || true)
signed_feed=$(helm_bundle_value "$plist" SURequireSignedFeed || true)
verify_before_extraction=$(
    helm_bundle_value "$plist" SUVerifyUpdateBeforeExtraction || true
)
signed_feed_failure_expiration=$(
    helm_bundle_value "$plist" SUSignedFeedFailureExpirationInterval || true
)
automatic_checks=$(helm_bundle_value "$plist" SUEnableAutomaticChecks || true)
sparkle_framework="$project_root/macos-app/.vendor/Sparkle.framework"
sparkle_binary="$sparkle_framework/Versions/B/Sparkle"
sparkle_info="$sparkle_framework/Versions/B/Resources/Info.plist"
sparkle_source="$project_root/macos-app/Sources/SparkleUpdater.swift"
sparkle_version_file="$project_root/macos-app/ThirdParty/Sparkle.version"
sparkle_hash_file="$project_root/macos-app/ThirdParty/Sparkle.sha256"
sparkle_version=$(tr -d '[:space:]' <"$sparkle_version_file" 2>/dev/null || true)
sparkle_hash=$(tr -d '[:space:]' <"$sparkle_hash_file" 2>/dev/null || true)
embedded_version=$(helm_bundle_value "$sparkle_info" CFBundleShortVersionString || true)
sparkle_integrity_ready=true
sparkle_archive_snapshot=${release_inputs:+"$release_inputs/Sparkle.tar.xz"}

[[ $sparkle_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $embedded_version == "$sparkle_version" ]] || sparkle_integrity_ready=false
[[ -f $sparkle_binary && -f $sparkle_source ]] || sparkle_integrity_ready=false
if [[ -z $release_inputs ]] \
    || ! helm_snapshot_regular_file \
        "${HELM_SPARKLE_ARCHIVE:-}" "$sparkle_archive_snapshot" \
    || ! helm_sha256_matches "$sparkle_archive_snapshot" "$sparkle_hash"; then
    sparkle_integrity_ready=false
fi
codesign --verify --deep --strict "$sparkle_framework" >/dev/null 2>&1 || sparkle_integrity_ready=false
lipo -archs "$sparkle_binary" 2>/dev/null | tr ' ' '\n' | grep -qx arm64 || sparkle_integrity_ready=false
grep -Fq 'SPUStandardUpdaterController' "$sparkle_source" 2>/dev/null || sparkle_integrity_ready=false
grep -Fq -- '-framework Sparkle' "$project_root/macos-app/scripts/build-and-install.sh" 2>/dev/null || sparkle_integrity_ready=false

if [[ -f $sparkle_archive_snapshot ]]; then
    sparkle_extract=$(mktemp -d /tmp/helm-sparkle-preflight.XXXXXX)
    if ! tar -xf "$sparkle_archive_snapshot" -C "$sparkle_extract" >/dev/null 2>&1 \
        || ! helm_trees_match_without_signatures \
            "$sparkle_extract/Sparkle.framework" "$sparkle_framework"; then
        sparkle_integrity_ready=false
    fi
fi

if [[ $sparkle_integrity_ready == true ]]; then
    pass_gate sparkle_integrity "the pinned archive exactly matches the signed framework, architecture, source, and build linkage"
else
    block_gate sparkle_integrity "verify and integrate the exact pinned Sparkle archive and framework"
fi

feed_url_valid=false
if helm_valid_https_url "$feed_url"; then
    feed_url_valid=true
    pass_gate sparkle_feed_url "the embedded feed uses a canonical credential-free HTTPS URL"
else
    block_gate sparkle_feed_url "configure a canonical credential-free HTTPS feed URL"
fi

if [[ $feed_url_valid == true && -n $public_key && $signed_feed == "true" \
    && $verify_before_extraction == "true" \
    && $signed_feed_failure_expiration == "0" \
    && $automatic_checks == "false" ]]; then
    pass_gate sparkle_feed "signed HTTPS updates are verified before extraction, fail closed permanently, and keep background checks disabled"
else
    block_gate sparkle_feed "require the signed production feed, pre-extraction verification, non-expiring signature failures, and disabled automatic checks"
fi

history_anchor=$(helm_tracked_regular_file_value \
    "$project_root" "$release_source_commit" \
    macos-app/Release/PreviousAppcast.sha256 2>/dev/null \
    | tr -d '[:space:]' || true)
if helm_valid_sha256 "$history_anchor"; then
    pass_gate release_history_anchor "the reviewed prior signed appcast SHA-256 is pinned in the source tree"
else
    block_gate release_history_anchor "pin the signed genesis or immediately preceding immutable-release appcast SHA-256"
fi

sdl_framework="$project_root/macos-app/.vendor/SDL3.framework"
sdl_version_file="$project_root/macos-app/ThirdParty/SDL.version"
sdl_hash_file="$project_root/macos-app/ThirdParty/SDL.sha256"
sdl_version=$(tr -d '[:space:]' <"$sdl_version_file" 2>/dev/null || true)
sdl_hash=$(tr -d '[:space:]' <"$sdl_hash_file" 2>/dev/null || true)
sdl_embedded_version=$(helm_bundle_value \
    "$sdl_framework/Versions/A/Resources/Info.plist" \
    CFBundleShortVersionString || true)
sdl_archive_snapshot=${release_inputs:+"$release_inputs/SDL3.dmg"}
sdl_integrity_ready=true
sdl_source_framework=""

[[ $sdl_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ \
    && $sdl_embedded_version == "$sdl_version" ]] || sdl_integrity_ready=false
if [[ -z $release_inputs ]] \
    || ! helm_snapshot_regular_file \
        "${HELM_SDL_ARCHIVE:-}" "$sdl_archive_snapshot" \
    || ! helm_sha256_matches "$sdl_archive_snapshot" "$sdl_hash"; then
    sdl_integrity_ready=false
fi
if [[ $sdl_integrity_ready == true ]]; then
    sdl_mount=$(mktemp -d /tmp/helm-sdl-preflight.XXXXXX 2>/dev/null || true)
    if [[ -z $sdl_mount ]] \
        || ! helm_mount_readonly_dmg "$sdl_archive_snapshot" "$sdl_mount"; then
        sdl_integrity_ready=false
    else
        sdl_mounted=true
        sdl_source_framework="$sdl_mount/SDL3.xcframework/macos-arm64_x86_64/SDL3.framework"
    fi
fi
if [[ $sdl_integrity_ready == true ]] \
    && [[ -d $sdl_source_framework && -f $sdl_framework/SDL3 ]] \
    && codesign --verify --deep --strict "$sdl_source_framework" >/dev/null 2>&1 \
    && codesign --verify --deep --strict "$sdl_framework" >/dev/null 2>&1 \
    && helm_trees_match_without_signatures \
        "$sdl_source_framework" "$sdl_framework" \
    && lipo -archs "$sdl_framework/SDL3" 2>/dev/null \
        | tr ' ' '\n' | grep -qx arm64 \
    && grep -Fq -- '-framework SDL3' \
        "$project_root/macos-app/scripts/build-and-install.sh" 2>/dev/null; then
    pass_gate sdl_integrity "the embedded SDL tree exactly matches the hash-pinned official DMG after signature normalization"
else
    block_gate sdl_integrity "verify the exact pinned SDL DMG and embedded framework content"
fi

entitlements="$project_root/macos-app/Resources/Helm.entitlements"
if helm_entitlements_are_exact "$entitlements"; then
    pass_gate entitlements_exact "release entitlements exactly match the one-key audio-input allowlist"
else
    block_gate entitlements_exact "release entitlements must contain only the required audio-input entitlement"
fi

artifact_verifier="$script_dir/verify-release-artifact.sh"
if [[ -x $artifact_verifier ]]; then
    pass_gate artifact_verifier "final signed/notarized/update artifact verifier is installed"
else
    block_gate artifact_verifier "install the executable final-artifact verifier"
fi

if ((blocked > 0)); then
    printf 'RELEASE_PREFLIGHT=BLOCKED blocked_gates=%d\n' "$blocked"
    exit 2
fi

printf 'RELEASE_PREFLIGHT=PASS\n'

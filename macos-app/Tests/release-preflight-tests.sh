#!/usr/bin/env bash

set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
script="$test_dir/../scripts/release-preflight.sh"
artifact_script="$test_dir/../scripts/verify-release-artifact.sh"
fixture_dir=$(mktemp -d /tmp/helm-release-preflight.XXXXXX)
trap 'rm -rf "$fixture_dir"' EXIT

[[ $(tr -d '[:space:]' <"$test_dir/../ThirdParty/SDL.version") \
    =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ $(tr -d '[:space:]' <"$test_dir/../ThirdParty/SDL.sha256") \
    =~ ^[0-9a-f]{64}$ ]]

help_output=$("$script" --help)
grep -q 'Developer ID' <<<"$help_output"
grep -q 'Sparkle' <<<"$help_output"
grep -q 'HELM_EXPECTED_TEAM_ID' <<<"$help_output"
grep -q 'HELM_DEVELOPER_IDENTITY_SHA1' <<<"$help_output"
grep -q 'HELM_SPARKLE_ARCHIVE' <<<"$help_output"
grep -q 'HELM_SDL_ARCHIVE' <<<"$help_output"
grep -q 'HELM_RELEASE_SOURCE_COMMIT' <<<"$help_output"
grep -Fq 'SDL3.xcframework/macos-arm64_x86_64/SDL3.framework' "$script"
grep -Fq 'macos-app/ThirdParty/SDL.sha256' "$script"
grep -Fq 'macos-app/ThirdParty/SDL.version' "$script"
grep -q 'helm_trees_match_without_signatures' "$script"
grep -q 'helm_snapshot_regular_file' "$script"
grep -q 'helm_tree_manifest' "$test_dir/../scripts/release-lib.sh"
grep -q 'helm_signature_layout_is_expected' \
    "$test_dir/../scripts/release-lib.sh"
grep -q 'metadata.st_nlink != 1' \
    "$test_dir/../scripts/release-tree-manifest.py"
grep -q 'PROVENANCE_HEX_PREFIX' \
    "$test_dir/../scripts/release-tree-manifest.py"
grep -q 'RELEASE_CLEANUP=BLOCKED' "$script"
grep -q 'HELM_TREE_COMPARISON_CLEANUP_FAILED' "$script"
if grep -Eq 'helm_unmount_dmg .*\|\| true' "$script"; then
    echo "FAIL: preflight must not silently swallow a DMG detach failure" >&2
    exit 1
fi

set +e
output=$("$script" 2>&1)
status=$?
set -e

if [[ $status -eq 0 ]]; then
    echo "FAIL: an ad-hoc development tree must not pass formal release preflight" >&2
    exit 1
fi

for gate in git_clean release_source_commit formal_product_name signing_identity notary_profile sparkle_integrity sdl_integrity sparkle_feed_url sparkle_feed release_history_anchor entitlements_exact; do
    if ! grep -q "GATE $gate" <<<"$output"; then
        echo "FAIL: missing release gate $gate" >&2
        exit 1
    fi
done

grep -q 'RELEASE_PREFLIGHT=BLOCKED' <<<"$output"

fixture_project="$fixture_dir/project"
mkdir -p "$fixture_project/macos-app/scripts" \
    "$fixture_project/macos-app/Resources" \
    "$fixture_project/macos-app/ThirdParty" \
    "$fixture_project/macos-app/Sources"
cp "$test_dir/../scripts/release-lib.sh" \
    "$test_dir/../scripts/release-tree-manifest.py" \
    "$test_dir/../scripts/release-preflight.sh" \
    "$test_dir/../scripts/verify-release-artifact.sh" \
    "$fixture_project/macos-app/scripts/"
cp "$test_dir/../Resources/Info.plist" \
    "$test_dir/../Resources/Helm.entitlements" \
    "$fixture_project/macos-app/Resources/"
cp "$test_dir/../ThirdParty/Sparkle.version" \
    "$test_dir/../ThirdParty/Sparkle.sha256" \
    "$test_dir/../ThirdParty/SDL.version" \
    "$test_dir/../ThirdParty/SDL.sha256" \
    "$fixture_project/macos-app/ThirdParty/"
cp "$test_dir/../Sources/SparkleUpdater.swift" \
    "$fixture_project/macos-app/Sources/"
cp "$test_dir/../scripts/build-and-install.sh" \
    "$fixture_project/macos-app/scripts/"
fixture_plist="$fixture_project/macos-app/Resources/Info.plist"
plutil -replace SUFeedURL -string 'https://exa mple.com/path' "$fixture_plist"
plutil -replace SUPublicEDKey -string test-public-key "$fixture_plist"
plutil -replace SURequireSignedFeed -bool YES "$fixture_plist"
plutil -replace SUEnableAutomaticChecks -bool NO "$fixture_plist"
set +e
malformed_feed_output=$(
    "$fixture_project/macos-app/scripts/release-preflight.sh" 2>&1
)
malformed_feed_status=$?
set -e
if [[ $malformed_feed_status -eq 0 ]] \
    || ! grep -q 'GATE sparkle_feed_url BLOCKED' <<<"$malformed_feed_output"; then
    echo "FAIL: preflight must explicitly block a malformed embedded feed URL" >&2
    exit 1
fi

artifact_help=$($artifact_script --help)
grep -q 'notarization' <<<"$artifact_help"
grep -q 'Sparkle' <<<"$artifact_help"
grep -q 'appcast' <<<"$artifact_help"
grep -q 'PREVIOUS_SIGNED_APPCAST' <<<"$artifact_help"
grep -q 'HELM_RELEASE_SOURCE_COMMIT' <<<"$artifact_help"
grep -q 'HELM_SDL_ARCHIVE' <<<"$artifact_help"
if grep -q 'PREVIOUS_BUILD' <<<"$artifact_help"; then
    echo "FAIL: monotonicity must not trust a caller-provided previous build" >&2
    exit 1
fi
if grep -q 'HELM_PREVIOUS_BUILD\|previous_build=' "$artifact_script"; then
    echo "FAIL: the artifact verifier still contains a raw previous-build bypass" >&2
    exit 1
fi
if grep -q 'HELM_SPARKLE_TOOLS_DIR' <<<"$artifact_help" \
    || grep -q 'HELM_SPARKLE_TOOLS_DIR' "$artifact_script"; then
    echo "FAIL: Sparkle verification tools must come only from the pinned archive" >&2
    exit 1
fi
grep -q 'sparkle_extract/bin/sign_update' "$artifact_script"
grep -q 'PreviousAppcast.sha256' "$artifact_script"
grep -q 'helm_sha256_matches "$previous_appcast"' "$artifact_script"
grep -q 'helm_entitlements_are_empty' "$artifact_script"
grep -q 'nested-certificate-' "$artifact_script"
grep -q 'Versions/B/Autoupdate' "$artifact_script"
grep -Fq 'MacOS/Helm' "$artifact_script"
grep -Fq 'helm_macho_inventory_matches "$contents"' "$artifact_script"
grep -Fq 'SDL3.xcframework/macos-arm64_x86_64/SDL3.framework' "$artifact_script"
grep -Fq 'macos-app/ThirdParty/SDL.sha256' "$artifact_script"
grep -Fq 'macos-app/ThirdParty/SDL.version' "$artifact_script"
grep -q 'helm_trees_match_without_signatures' "$artifact_script"
grep -q 'helm_snapshot_regular_file' "$artifact_script"
grep -q 'RELEASE_CLEANUP=BLOCKED' "$artifact_script"
grep -q 'HELM_TREE_COMPARISON_CLEANUP_FAILED' "$artifact_script"
if grep -Eq 'helm_unmount_dmg .*\|\| true' "$artifact_script"; then
    echo "FAIL: final verification must not silently swallow a DMG detach failure" >&2
    exit 1
fi
grep -q 'helm_release_source_is_exact' "$artifact_script"
grep -q 'helm_tracked_regular_file_value' "$artifact_script"
grep -q "namespace-uri()" "$artifact_script"
grep -q 'helm_appcast_has_only_canonical_sparkle_attributes' "$artifact_script"
grep -q 'helm_valid_https_url' "$artifact_script"
grep -q "grep -Eq '\^Timestamp='" "$artifact_script"

set +e
artifact_output=$($artifact_script /Applications/Definitely-Missing-Helm.app 2>&1)
artifact_status=$?
set -e

if [[ $artifact_status -eq 0 ]]; then
    echo "FAIL: a missing release artifact must not pass verification" >&2
    exit 1
fi

for gate in product_name codesign hardened_runtime stapled_ticket update_urls sdl_embedded sparkle_embedded update_signature version_monotonic; do
    if ! grep -q "GATE $gate" <<<"$artifact_output"; then
        echo "FAIL: missing artifact gate $gate" >&2
        exit 1
    fi
done

grep -q 'RELEASE_ARTIFACT=BLOCKED' <<<"$artifact_output"

fixture_app="$fixture_dir/Helm.app"
mkdir -p "$fixture_app/Contents"
cp "$test_dir/../Resources/Info.plist" "$fixture_app/Contents/Info.plist"
plutil -replace SUFeedURL -string 'https://example.com/appcast.xml' \
    "$fixture_app/Contents/Info.plist"
set +e
malformed_update_output=$(HELM_EXPECTED_UPDATE_URL='https://example.com#' \
    "$artifact_script" "$fixture_app" 2>&1)
malformed_update_status=$?
set -e
if [[ $malformed_update_status -eq 0 ]] \
    || ! grep -q 'GATE update_urls BLOCKED' <<<"$malformed_update_output"; then
    echo "FAIL: final verification must explicitly block a malformed update URL" >&2
    exit 1
fi

echo "RELEASE_PREFLIGHT_TESTS=PASS"

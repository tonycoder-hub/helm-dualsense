#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
project_root=$(cd "$script_dir/../.." && pwd)
workflow="$project_root/.github/workflows/release.yml"
verify_workflow="$project_root/.github/workflows/verify.yml"
plist="$project_root/macos-app/Resources/Info.plist"
updater_policy="$project_root/macos-app/Sources/SparkleUpdateConfiguration.swift"
preflight="$project_root/macos-app/scripts/release-preflight.sh"
artifact_verifier="$project_root/macos-app/scripts/verify-release-artifact.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

require_literal() {
    local file=$1
    local literal=$2
    local description=$3
    grep -Fq -- "$literal" "$file" || fail "$description"
}

[[ -f $workflow ]] || fail "dedicated GitHub Release workflow is missing"
bash -n "$project_root/macos-app/scripts/build-and-install.sh"
plutil -lint "$plist" >/dev/null

require_literal "$workflow" "workflow_dispatch:" \
    "release workflow must require an explicit manual dispatch"
require_literal "$workflow" "environment: release" \
    "release workflow must use the dedicated release environment"
require_literal "$workflow" "contents: write" \
    "release workflow needs a narrowly scoped contents write grant"
require_literal "$workflow" "persist-credentials: false" \
    "checkout credentials must not persist beyond the checkout step"
require_literal "$workflow" "secrets.SPARKLE_PRIVATE_KEY" \
    "release signing must use the environment-scoped Sparkle secret"
require_literal "$workflow" "generate_appcast" \
    "release workflow must generate a signed Sparkle appcast"
require_literal "$workflow" "--ed-key-file -" \
    "Sparkle signing key must be passed over standard input"
require_literal "$workflow" "gh release create" \
    "release assets must be published through GitHub Releases"
require_literal "$workflow" "releases/download/\$TAG/" \
    "appcast enclosures must use immutable versioned release URLs"
require_literal "$workflow" "previous_appcast" \
    "release workflow must compare against the latest published appcast"
require_literal "$workflow" "sign_update" \
    "the previous signed appcast must be cryptographically verified"
require_literal "$workflow" 'shasum -a 256 "$(basename "$archive")" appcast.xml' \
    "release checksums must contain portable asset basenames"
require_literal "$verify_workflow" "github-release-contract-tests.sh" \
    "Verify must enforce the GitHub release contract"
require_literal "$verify_workflow" "core-build:" \
    "Verify must compile and exercise the controller application"
require_literal "$verify_workflow" "macos-app/scripts/build-and-install.sh" \
    "the protected core build must run the full Swift and C test path"
require_literal "$updater_policy" "SUVerifyUpdateBeforeExtraction" \
    "the updater must require verification before extraction"
require_literal "$updater_policy" "SUSignedFeedFailureExpirationInterval" \
    "the updater must fail closed after signed-feed validation failures"
require_literal "$preflight" "SUVerifyUpdateBeforeExtraction" \
    "formal preflight must enforce verification before extraction"
require_literal "$artifact_verifier" "SUVerifyUpdateBeforeExtraction" \
    "final artifact verification must enforce verification before extraction"

if grep -Eq 'pull_request_target:|[A-Za-z0-9_]*(TOKEN|KEY|SECRET)[[:space:]]*:[[:space:]]*[A-Za-z0-9+/=]{24,}' "$workflow"; then
    fail "release workflow contains a dangerous trigger or an inline secret"
fi

feed_url=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$plist")
public_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$plist")
signed_feed=$(/usr/libexec/PlistBuddy -c 'Print :SURequireSignedFeed' "$plist")
automatic_checks=$(/usr/libexec/PlistBuddy -c 'Print :SUEnableAutomaticChecks' "$plist")
verify_before_extraction=$(
    /usr/libexec/PlistBuddy -c 'Print :SUVerifyUpdateBeforeExtraction' "$plist"
)
signed_feed_failure_expiration=$(
    /usr/libexec/PlistBuddy \
        -c 'Print :SUSignedFeedFailureExpirationInterval' "$plist"
)

[[ $feed_url == \
    'https://github.com/tonycoder-hub/helm-dualsense/releases/latest/download/appcast.xml' ]] \
    || fail "Sparkle feed must use the stable GitHub Releases latest asset URL"
[[ $public_key == 'WHwMtToEO+eNqAQI+pQS7fbBJ1IHC4aw0Vm5KEDizjg=' ]] \
    || fail "Sparkle public key does not match the dedicated Helm release key"
[[ $signed_feed == true ]] || fail "Sparkle must require a signed feed"
[[ $automatic_checks == false ]] \
    || fail "background checks must remain disabled for the first public release"
[[ $verify_before_extraction == true ]] \
    || fail "signed feeds must be verified before update extraction"
[[ $signed_feed_failure_expiration == 0 ]] \
    || fail "signed-feed failures must never expire into an unsigned fallback"

printf 'GITHUB_RELEASE_CONTRACT_TESTS=PASS\n'

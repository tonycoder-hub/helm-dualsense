#!/usr/bin/env bash

set -euo pipefail

readonly HELM_LOCAL_BUNDLE_ID="io.github.tonycoder-hub.helm"
readonly HELM_LOCAL_UPDATE_IDENTITY="io.github.tonycoder-hub.helm.local-v1"

# This anchorless identity is only for a single-user local Demo. Public builds
# must use the fail-closed Developer ID/notarization path instead.

helm_local_designated_requirement() {
    printf '%s\n' \
        "designated => identifier \"$HELM_LOCAL_BUNDLE_ID\" and info[HelmLocalUpdateIdentity] = \"$HELM_LOCAL_UPDATE_IDENTITY\""
}

helm_local_app_requirement() {
    local app=$1
    codesign -d -r- "$app" 2>&1 | sed -n '/^designated =>/p'
}

helm_verify_local_app_identity() {
    local app=$1
    local expected
    local actual
    codesign --verify --deep --strict "$app"
    expected=$(helm_local_designated_requirement)
    actual=$(helm_local_app_requirement "$app")
    if [[ "$actual" != "$expected" ]]; then
        echo "Local app designated requirement does not match the stable Helm identity." >&2
        return 1
    fi
}

helm_sign_local_app() {
    local app=$1
    local info_plist="$app/Contents/Info.plist"
    local bundle_id
    local update_identity
    local requirement

    bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")
    update_identity=$(
        /usr/libexec/PlistBuddy -c 'Print :HelmLocalUpdateIdentity' "$info_plist"
    )
    if [[ "$bundle_id" != "$HELM_LOCAL_BUNDLE_ID" \
        || "$update_identity" != "$HELM_LOCAL_UPDATE_IDENTITY" ]]; then
        echo "Refusing to sign an app without Helm's fixed local identity marker." >&2
        return 1
    fi

    requirement=$(helm_local_designated_requirement)
    codesign --force --sign - --timestamp=none \
        --identifier "$HELM_LOCAL_BUNDLE_ID" \
        --requirements "=$requirement" \
        "$app"
    helm_verify_local_app_identity "$app"
}

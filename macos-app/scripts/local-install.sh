#!/usr/bin/env bash

set -euo pipefail

helm_install_app_contents() {
    local staged_app=$1
    local installed_app=$2
    local verifier=$3
    local install_root
    local rollback_dir

    if [[ ! -d "$staged_app/Contents" ]]; then
        echo "Staged application has no Contents directory: $staged_app" >&2
        return 2
    fi

    install_root=$(dirname "$installed_app")
    mkdir -p "$install_root"

    if [[ ! -e "$installed_app" ]]; then
        mkdir -p "$installed_app"
        ditto "$staged_app/Contents" "$installed_app/Contents"
        if "$verifier" "$installed_app"; then
            return 0
        fi
        rm -rf "$installed_app"
        return 1
    fi

    if [[ ! -d "$installed_app/Contents" ]]; then
        echo "Installed application has no Contents directory: $installed_app" >&2
        return 2
    fi

    rollback_dir=$(mktemp -d "$install_root/.Helm-Demo-rollback.XXXXXX")
    mv "$installed_app/Contents" "$rollback_dir/Contents"

    if ditto "$staged_app/Contents" "$installed_app/Contents" \
        && "$verifier" "$installed_app"; then
        rm -rf "$rollback_dir"
        return 0
    fi

    rm -rf "$installed_app/Contents"
    mv "$rollback_dir/Contents" "$installed_app/Contents"
    rmdir "$rollback_dir"
    return 1
}

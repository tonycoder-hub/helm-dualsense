#!/usr/bin/env bash

set -euo pipefail

helm_migrate_legacy_app_path() {
    local legacy_app=$1
    local installed_app=$2
    local verifier=$3
    local inode_before
    local inode_after

    if [[ -e "$installed_app" || -L "$installed_app" ]]; then
        if [[ -e "$legacy_app" || -L "$legacy_app" ]]; then
            echo "Both legacy and current application paths exist; refusing to choose one." >&2
            return 2
        fi
        if [[ ! -d "$installed_app" || -L "$installed_app" ]]; then
            echo "Current application path is not a regular bundle directory: $installed_app" >&2
            return 2
        fi
        if ! "$verifier" "$installed_app"; then
            echo "Current application failed identity verification: $installed_app" >&2
            return 1
        fi
        return 0
    fi

    if [[ ! -e "$legacy_app" && ! -L "$legacy_app" ]]; then
        return 0
    fi
    if [[ ! -d "$legacy_app" || -L "$legacy_app" ]]; then
        echo "Legacy application is not a regular bundle directory: $legacy_app" >&2
        return 2
    fi
    if ! "$verifier" "$legacy_app"; then
        echo "Legacy application failed identity verification: $legacy_app" >&2
        return 1
    fi

    inode_before=$(stat -f '%i' "$legacy_app")
    if ! mv "$legacy_app" "$installed_app"; then
        echo "Could not rename the legacy application to: $installed_app" >&2
        return 1
    fi

    inode_after=$(stat -f '%i' "$installed_app" 2>/dev/null || true)
    if [[ $inode_before == "$inode_after" ]] && "$verifier" "$installed_app"; then
        return 0
    fi

    echo "Renamed application failed inode or identity verification; restoring legacy path." >&2
    if [[ ! -e "$legacy_app" && -d "$installed_app" ]] \
        && mv "$installed_app" "$legacy_app"; then
        return 1
    fi
    echo "Could not restore the legacy application path." >&2
    return 3
}

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
    if [[ -L "$installed_app" ]]; then
        echo "Installed application path must not be a symbolic link: $installed_app" >&2
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

    rollback_dir=$(mktemp -d "$install_root/.GripPilot-rollback.XXXXXX")
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

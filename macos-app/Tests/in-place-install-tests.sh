#!/usr/bin/env bash

set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
source "$test_dir/../scripts/local-install.sh"

workspace=$(mktemp -d /tmp/helm-in-place-install.XXXXXX)
cleanup() {
    rm -rf "$workspace"
}
trap cleanup EXIT

installed="$workspace/Helm Demo.app"
staged="$workspace/Staged.app"
mkdir -p "$installed/Contents" "$staged/Contents"
printf 'old\n' > "$installed/Contents/obsolete.txt"
printf 'new\n' > "$staged/Contents/current.txt"
root_inode_before=$(stat -f '%i' "$installed")

verify_current() {
    [[ -f "$1/Contents/current.txt" && ! -e "$1/Contents/obsolete.txt" ]]
}

helm_install_app_contents "$staged" "$installed" verify_current

root_inode_after=$(stat -f '%i' "$installed")
[[ "$root_inode_before" == "$root_inode_after" ]]
verify_current "$installed"
[[ -z $(find "$workspace" -maxdepth 1 -name '.Helm-Demo-rollback.*' -print -quit) ]]

rejected="$workspace/Rejected.app"
mkdir -p "$rejected/Contents"
printf 'bad\n' > "$rejected/Contents/rejected.txt"

reject_install() {
    return 1
}

if helm_install_app_contents "$rejected" "$installed" reject_install; then
    echo "expected verifier rejection" >&2
    exit 1
fi

[[ "$root_inode_before" == "$(stat -f '%i' "$installed")" ]]
verify_current "$installed"
[[ ! -e "$installed/Contents/rejected.txt" ]]
[[ -z $(find "$workspace" -maxdepth 1 -name '.Helm-Demo-rollback.*' -print -quit) ]]

echo "IN_PLACE_INSTALL_TESTS=PASS"

#!/usr/bin/env bash

set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
source "$test_dir/../scripts/local-install.sh"

workspace=$(mktemp -d /tmp/grippilot-path-migration.XXXXXX)
cleanup() {
    rm -rf "$workspace"
}
trap cleanup EXIT

verify_fixture() {
    [[ -f "$1/Contents/identity.txt" ]]
}

legacy="$workspace/Helm Demo.app"
installed="$workspace/GripPilot.app"
mkdir -p "$legacy/Contents"
printf 'stable identity\n' > "$legacy/Contents/identity.txt"
inode_before=$(stat -f '%i' "$legacy")

helm_migrate_legacy_app_path "$legacy" "$installed" verify_fixture

[[ ! -e "$legacy" ]]
[[ -d "$installed" ]]
[[ $inode_before == "$(stat -f '%i' "$installed")" ]]
verify_fixture "$installed"

collision_legacy="$workspace/Collision Helm Demo.app"
collision_target="$workspace/Collision GripPilot.app"
mkdir -p "$collision_legacy/Contents" "$collision_target/Contents"
printf 'legacy\n' > "$collision_legacy/Contents/identity.txt"
printf 'target\n' > "$collision_target/Contents/identity.txt"

if helm_migrate_legacy_app_path \
    "$collision_legacy" "$collision_target" verify_fixture 2>/dev/null; then
    echo "expected an existing-path collision to be rejected" >&2
    exit 1
fi

[[ $(<"$collision_legacy/Contents/identity.txt") == "legacy" ]]
[[ $(<"$collision_target/Contents/identity.txt") == "target" ]]

foreign_target="$workspace/Foreign GripPilot.app"
mkdir -p "$foreign_target/Contents"
printf 'foreign\n' > "$foreign_target/Contents/unrelated.txt"
if helm_migrate_legacy_app_path \
    "$workspace/Missing Helm Demo.app" "$foreign_target" verify_fixture 2>/dev/null; then
    echo "expected an unrelated target app to be rejected" >&2
    exit 1
fi
[[ $(<"$foreign_target/Contents/unrelated.txt") == "foreign" ]]

valid_target="$workspace/Valid GripPilot.app"
mkdir -p "$valid_target/Contents"
printf 'stable identity\n' > "$valid_target/Contents/identity.txt"
helm_migrate_legacy_app_path \
    "$workspace/Another Missing Helm Demo.app" "$valid_target" verify_fixture

outside_target="$workspace/Outside.app"
linked_target="$workspace/Linked GripPilot.app"
mkdir -p "$outside_target/Contents"
printf 'outside\n' > "$outside_target/Contents/identity.txt"
ln -s "$outside_target" "$linked_target"
if helm_migrate_legacy_app_path \
    "$workspace/Symlink Missing Helm Demo.app" "$linked_target" verify_fixture 2>/dev/null; then
    echo "expected a symlink target app to be rejected" >&2
    exit 1
fi
[[ -L "$linked_target" ]]
[[ $(<"$outside_target/Contents/identity.txt") == "outside" ]]

invalid_legacy="$workspace/Invalid Helm Demo.app"
invalid_target="$workspace/Invalid GripPilot.app"
mkdir -p "$invalid_legacy/Contents"
printf 'foreign\n' > "$invalid_legacy/Contents/unrelated.txt"
invalid_inode=$(stat -f '%i' "$invalid_legacy")
if helm_migrate_legacy_app_path \
    "$invalid_legacy" "$invalid_target" verify_fixture 2>/dev/null; then
    echo "expected an invalid legacy app to be rejected before migration" >&2
    exit 1
fi
[[ -d "$invalid_legacy" && ! -e "$invalid_target" ]]
[[ $invalid_inode == "$(stat -f '%i' "$invalid_legacy")" ]]

rollback_legacy="$workspace/Rollback Helm Demo.app"
rollback_target="$workspace/Rollback GripPilot.app"
mkdir -p "$rollback_legacy/Contents"
printf 'stable identity\n' > "$rollback_legacy/Contents/identity.txt"
rollback_inode=$(stat -f '%i' "$rollback_legacy")
verify_legacy_path_only() {
    [[ $1 == "$rollback_legacy" && -f "$1/Contents/identity.txt" ]]
}
if helm_migrate_legacy_app_path \
    "$rollback_legacy" "$rollback_target" verify_legacy_path_only 2>/dev/null; then
    echo "expected post-move verification failure to roll back" >&2
    exit 1
fi
[[ -d "$rollback_legacy" && ! -e "$rollback_target" ]]
[[ $rollback_inode == "$(stat -f '%i' "$rollback_legacy")" ]]
verify_fixture "$rollback_legacy"

echo "BUNDLE_PATH_MIGRATION_TESTS=PASS"

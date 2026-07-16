#!/usr/bin/env bash

set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
source "$test_dir/../scripts/release-lib.sh"

fixture_dir=$(mktemp -d /tmp/helm-release-security.XXXXXX)
trap 'rm -rf "$fixture_dir"' EXIT

allowed="$fixture_dir/allowed.plist"
extra="$fixture_dir/extra.plist"
cp "$test_dir/../Resources/Helm.entitlements" "$allowed"
cp "$allowed" "$extra"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.allow-jit bool true' "$extra"

helm_entitlements_are_exact "$allowed"
if helm_entitlements_are_exact "$extra"; then
    echo "FAIL: extra release entitlements must be rejected" >&2
    exit 1
fi
empty_entitlements="$fixture_dir/empty-entitlements.plist"
cp "$allowed" "$empty_entitlements"
/usr/libexec/PlistBuddy \
    -c 'Delete :com.apple.security.device.audio-input' "$empty_entitlements"
helm_entitlements_are_empty "$empty_entitlements"
if helm_entitlements_are_empty "$allowed"; then
    echo "FAIL: nested code must not gain the app audio-input entitlement" >&2
    exit 1
fi

helm_valid_team_id ABCDE12345
if helm_valid_team_id short; then
    echo "FAIL: malformed Team ID must be rejected" >&2
    exit 1
fi

helm_valid_identity_sha1 0123456789abcdef0123456789ABCDEF01234567
if helm_valid_identity_sha1 not-a-fingerprint; then
    echo "FAIL: malformed identity fingerprint must be rejected" >&2
    exit 1
fi

expected_identity=0123456789ABCDEF0123456789ABCDEF01234567
other_identity=89ABCDEF0123456789ABCDEF0123456789ABCDEF
matching_identities="  1) $expected_identity \"Developer ID Application: Helm (ABCDE12345)\""
helm_identity_record_matches "$matching_identities" "$expected_identity" ABCDE12345
crossed_identities=$(printf '%s\n%s\n' \
    "  1) $expected_identity \"Apple Development: Other (ZZZZZ99999)\"" \
    "  2) $other_identity \"Developer ID Application: Helm (ABCDE12345)\"")
if helm_identity_record_matches "$crossed_identities" "$expected_identity" ABCDE12345; then
    echo "FAIL: identity fields from different records must not be combined" >&2
    exit 1
fi
spoofed_identity="  1) $other_identity \"Developer ID Application: $expected_identity Helm (ABCDE12345)\""
if helm_identity_record_matches "$spoofed_identity" "$expected_identity" ABCDE12345; then
    echo "FAIL: identity fingerprint text in a label must not satisfy the positional hash field" >&2
    exit 1
fi

expected_certificate=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
other_certificate=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
matching_certificate=$(printf 'SHA-256 hash: %s\nSHA-1 hash: %s\n"labl"="Developer ID Application: Helm (ABCDE12345)"\n' \
    "$expected_certificate" "$expected_identity")
helm_certificate_record_matches \
    "$matching_certificate" "$expected_identity" "$expected_certificate" ABCDE12345
crossed_certificates=$(printf 'SHA-256 hash: %s\nSHA-1 hash: %s\n"labl"="Developer ID Application: Helm (ABCDE12345)"\nSHA-256 hash: %s\nSHA-1 hash: %s\n"labl"="Developer ID Application: Helm (ABCDE12345)"\n' \
    "$expected_certificate" "$other_identity" "$other_certificate" "$expected_identity")
if helm_certificate_record_matches \
    "$crossed_certificates" "$expected_identity" "$expected_certificate" ABCDE12345; then
    echo "FAIL: SHA-1 and SHA-256 values from different certificates must not be combined" >&2
    exit 1
fi
spoofed_certificate=$(printf 'SHA-256 hash: %s\nSHA-1 hash: %s\n"labl"="Developer ID Application: %s %s Helm (ABCDE12345)"\n' \
    "$other_certificate" "$other_identity" "$expected_certificate" "$expected_identity")
if helm_certificate_record_matches \
    "$spoofed_certificate" "$expected_identity" "$expected_certificate" ABCDE12345; then
    echo "FAIL: certificate hashes mentioned only in a label must not satisfy anchored fields" >&2
    exit 1
fi

printf 'pinned release archive' >"$fixture_dir/archive"
archive_hash=$(shasum -a 256 "$fixture_dir/archive" | awk '{print $1}')
helm_sha256_matches "$fixture_dir/archive" "$archive_hash"
if helm_sha256_matches "$fixture_dir/archive" "${archive_hash%?}0"; then
    echo "FAIL: a substituted archive must be rejected" >&2
    exit 1
fi
snapshot="$fixture_dir/archive-snapshot"
helm_snapshot_regular_file "$fixture_dir/archive" "$snapshot"
printf 'post-snapshot replacement' >"$fixture_dir/archive"
helm_sha256_matches "$snapshot" "$archive_hash"
ln -s "$fixture_dir/archive" "$fixture_dir/archive-link"
if helm_snapshot_regular_file \
    "$fixture_dir/archive-link" "$fixture_dir/symlink-snapshot"; then
    echo "FAIL: a symlinked release input must not be snapshotted" >&2
    exit 1
fi
printf 'latest signed appcast' >"$fixture_dir/latest-appcast"
printf 'older signed appcast' >"$fixture_dir/older-appcast"
latest_appcast_hash=$(shasum -a 256 "$fixture_dir/latest-appcast" | awk '{print $1}')
helm_sha256_matches "$fixture_dir/latest-appcast" "$latest_appcast_hash"
if helm_sha256_matches "$fixture_dir/older-appcast" "$latest_appcast_hash"; then
    echo "FAIL: an authentic but stale prior appcast must not match the reviewed latest-history anchor" >&2
    exit 1
fi

mkdir -p "$fixture_dir/source/Resources" "$fixture_dir/source/_CodeSignature"
mkdir -p "$fixture_dir/candidate/Resources" "$fixture_dir/candidate/_CodeSignature"
printf 'trusted resource' >"$fixture_dir/source/Resources/value"
printf 'trusted resource' >"$fixture_dir/candidate/Resources/value"
printf 'upstream signature' >"$fixture_dir/source/_CodeSignature/CodeResources"
printf 'release signature' >"$fixture_dir/candidate/_CodeSignature/CodeResources"
helm_trees_match_without_signatures "$fixture_dir/source" "$fixture_dir/candidate"

cleanup_failure_work="$fixture_dir/comparator-cleanup-failure"
mkdir -p "$cleanup_failure_work"
touch "$cleanup_failure_work/immutable"
chflags uchg "$cleanup_failure_work/immutable"
mktemp() {
    printf '%s\n' "$cleanup_failure_work"
}
HELM_TREE_COMPARISON_CLEANUP_FAILED=false
set +e
helm_trees_match_without_signatures \
    "$fixture_dir/source" "$fixture_dir/candidate" >/dev/null 2>&1
cleanup_failure_status=$?
set -e
unset -f mktemp
chflags nouchg "$cleanup_failure_work/immutable"
/bin/rm -rf -- "$cleanup_failure_work"
if [[ $cleanup_failure_status -ne 3 \
    || $HELM_TREE_COMPARISON_CLEANUP_FAILED != true ]]; then
    echo "FAIL: comparator cleanup failure must return 3 and reach top-level cleanup" >&2
    exit 1
fi
HELM_TREE_COMPARISON_CLEANUP_FAILED=false

printf 'substituted resource' >"$fixture_dir/candidate/Resources/value"
if helm_trees_match_without_signatures "$fixture_dir/source" "$fixture_dir/candidate"; then
    echo "FAIL: modified framework content must not match the pinned tree" >&2
    exit 1
fi
printf 'trusted resource' >"$fixture_dir/candidate/Resources/value"
chmod +x "$fixture_dir/candidate/Resources/value"
if helm_trees_match_without_signatures "$fixture_dir/source" "$fixture_dir/candidate"; then
    echo "FAIL: a mode-only framework change must be rejected" >&2
    exit 1
fi
chmod -x "$fixture_dir/candidate/Resources/value"

ln -s value "$fixture_dir/candidate/Resources/extra-link"
if helm_trees_match_without_signatures "$fixture_dir/source" "$fixture_dir/candidate"; then
    echo "FAIL: an extra framework symlink must be rejected" >&2
    exit 1
fi
unlink "$fixture_dir/candidate/Resources/extra-link"

ln -s value "$fixture_dir/source/Resources/link-one"
ln -s value "$fixture_dir/source/Resources/link-two"
ln -s value "$fixture_dir/candidate/Resources/link-one"
ln -P "$fixture_dir/candidate/Resources/link-one" \
    "$fixture_dir/candidate/Resources/link-two"
if helm_trees_match_without_signatures "$fixture_dir/source" "$fixture_dir/candidate"; then
    echo "FAIL: changed symlink hard-link topology must be rejected" >&2
    exit 1
fi
unlink "$fixture_dir/source/Resources/link-one"
unlink "$fixture_dir/source/Resources/link-two"
unlink "$fixture_dir/candidate/Resources/link-one"
unlink "$fixture_dir/candidate/Resources/link-two"

mkfifo "$fixture_dir/candidate/Resources/blocked-fifo"
/usr/bin/python3 - "$test_dir/../scripts/release-tree-manifest.py" \
    "$fixture_dir/candidate" <<'PY'
import os
import signal
import subprocess
import sys

process = subprocess.Popen(
    ["/usr/bin/python3", sys.argv[1], sys.argv[2]],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    start_new_session=True,
)
try:
    status = process.wait(timeout=2)
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGKILL)
    process.wait()
    raise SystemExit("FAIL: an unsupported FIFO must be rejected without hanging")
if status == 0:
    raise SystemExit("FAIL: an unsupported FIFO must not enter the manifest")
PY
unlink "$fixture_dir/candidate/Resources/blocked-fifo"

printf '#!/bin/sh\nexit 0\n' \
    >"$fixture_dir/candidate/_CodeSignature/unsigned-helper"
chmod +x "$fixture_dir/candidate/_CodeSignature/unsigned-helper"
if helm_trees_match_without_signatures "$fixture_dir/source" "$fixture_dir/candidate"; then
    echo "FAIL: an extra _CodeSignature payload must be rejected" >&2
    exit 1
fi
unlink "$fixture_dir/candidate/_CodeSignature/unsigned-helper"

xattr -w com.helm.test changed "$fixture_dir/candidate/Resources/value"
if helm_trees_match_without_signatures "$fixture_dir/source" "$fixture_dir/candidate"; then
    echo "FAIL: an unapproved xattr-only change must be rejected" >&2
    exit 1
fi
xattr -d com.helm.test "$fixture_dir/candidate/Resources/value"

/usr/bin/python3 - "$test_dir/../scripts/release-tree-manifest.py" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("release_tree_manifest", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
valid_values = (
    "01 02 00 42 5D 64 8A D2 C9 A6 D0\n",
    "01020001b4264c7b53197b",
    "010200d8ab6ef7ca277cf4",
)
invalid_values = (
    "00",
    "0102000000000000000000",
    "02020042 5d64 8ad2 c9a6 d0",
    "01020042 5d64 8ad2 c9a6",
    "01020042 5d64 8ad2 c9a6 d000",
    "01020042 5d64 8ad2 c9a6 zz",
)
if not all(module.provenance_hex_is_allowed(value) for value in valid_values):
    raise SystemExit("FAIL: valid nonzero provenance lineage IDs must be accepted")
if any(module.provenance_hex_is_allowed(value) for value in invalid_values):
    raise SystemExit("FAIL: malformed provenance encodings must be rejected")
PY

xattr -wx com.apple.provenance 010200425d648ad2c9a6d0 \
    "$fixture_dir/candidate/Resources/value"
helm_trees_match_without_signatures "$fixture_dir/source" "$fixture_dir/candidate"
xattr -d com.apple.provenance "$fixture_dir/candidate/Resources/value"

chmod +a "user:$(id -un) allow read" "$fixture_dir/candidate/Resources/value"
if helm_trees_match_without_signatures "$fixture_dir/source" "$fixture_dir/candidate"; then
    echo "FAIL: an ACL-only change must be rejected" >&2
    exit 1
fi
chmod -N "$fixture_dir/candidate/Resources/value"

chflags uchg "$fixture_dir/candidate/Resources/value"
if helm_trees_match_without_signatures "$fixture_dir/source" "$fixture_dir/candidate"; then
    chflags nouchg "$fixture_dir/candidate/Resources/value"
    echo "FAIL: a file-flag-only change must be rejected" >&2
    exit 1
fi
chflags nouchg "$fixture_dir/candidate/Resources/value"

printf 'trusted resource' >"$fixture_dir/source/Resources/hardlinked"
ln "$fixture_dir/candidate/Resources/value" \
    "$fixture_dir/candidate/Resources/hardlinked"
if helm_trees_match_without_signatures "$fixture_dir/source" "$fixture_dir/candidate"; then
    echo "FAIL: changed hard-link topology must be rejected" >&2
    exit 1
fi
unlink "$fixture_dir/source/Resources/hardlinked"
unlink "$fixture_dir/candidate/Resources/hardlinked"

mkdir -p "$fixture_dir/macho-source" "$fixture_dir/macho-candidate"
cp /bin/echo "$fixture_dir/macho-source/tool"
cp /bin/echo "$fixture_dir/macho-candidate/tool"
codesign --force --sign - "$fixture_dir/macho-candidate/tool" >/dev/null 2>&1
helm_trees_match_without_signatures \
    "$fixture_dir/macho-source" "$fixture_dir/macho-candidate"

mkdir -p "$fixture_dir/zip-source/Helm.app"
printf 'app payload' >"$fixture_dir/zip-source/Helm.app/payload"
(cd "$fixture_dir/zip-source" && zip -qry "$fixture_dir/good.zip" Helm.app)
helm_zip_entries_are_scoped "$fixture_dir/good.zip" Helm.app
printf 'unexpected payload' >"$fixture_dir/zip-source/extra.txt"
(cd "$fixture_dir/zip-source" && zip -q "$fixture_dir/bad.zip" extra.txt)
if helm_zip_entries_are_scoped "$fixture_dir/bad.zip" Helm.app; then
    echo "FAIL: a ZIP with an extra top-level payload must be rejected" >&2
    exit 1
fi

mkdir -p "$fixture_dir/safe-app/data"
printf 'inside' >"$fixture_dir/safe-app/data/value"
ln -s data/value "$fixture_dir/safe-app/internal-link"
helm_tree_symlinks_are_internal "$fixture_dir/safe-app"
ln -s /etc/passwd "$fixture_dir/safe-app/escaping-link"
if helm_tree_symlinks_are_internal "$fixture_dir/safe-app"; then
    echo "FAIL: a symlink escaping the app must be rejected" >&2
    exit 1
fi

helm_decimal_gt 100000000000000000000 99999999999999999999
if helm_decimal_gt 42 42 || helm_decimal_gt 41 42; then
    echo "FAIL: decimal build comparison must be strictly monotonic" >&2
    exit 1
fi

appcast="$fixture_dir/appcast.xml"
printf '%s\n' \
    '<?xml version="1.0" encoding="utf-8"?>' \
    '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">' \
    '<channel><item><enclosure sparkle:version="7" /></item>' \
    '<item><enclosure sparkle:version="12" /></item>' \
    '<item><enclosure sparkle:version="9" /></item></channel></rss>' >"$appcast"
if [[ $(helm_appcast_max_build "$appcast") != "12" ]]; then
    echo "FAIL: previous build must be derived from the signed appcast maximum" >&2
    exit 1
fi
helm_appcast_has_only_canonical_sparkle_attributes "$appcast"

confused_appcast="$fixture_dir/confused-appcast.xml"
printf '%s\n' \
    '<?xml version="1.0" encoding="utf-8"?>' \
    '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:fake="https://attacker.invalid/sparkle">' \
    '<channel><item><enclosure sparkle:version="10" fake:version="20" sparkle:edSignature="real" fake:edSignature="fake" /></item></channel></rss>' \
    >"$confused_appcast"
if [[ $(helm_appcast_max_build "$confused_appcast") != "10" ]]; then
    echo "FAIL: unrelated XML namespaces must not define Sparkle build semantics" >&2
    exit 1
fi
if helm_appcast_has_only_canonical_sparkle_attributes "$confused_appcast"; then
    echo "FAIL: conflicting version or signature attributes in a fake namespace must be rejected" >&2
    exit 1
fi

helm_valid_https_url 'https://example.com/releases/appcast.xml'
if helm_valid_https_url 'https://' \
    || helm_valid_https_url 'http://example.com/appcast.xml' \
    || helm_valid_https_url 'https://user@example.com/appcast.xml' \
    || helm_valid_https_url 'https://example.com/appcast.xml#fragment' \
    || helm_valid_https_url 'https://example.com#' \
    || helm_valid_https_url 'https://example.com?x=y#' \
    || helm_valid_https_url 'https://exa mple.com/path' \
    || helm_valid_https_url $'https://exa\u00a0mple.com/path' \
    || helm_valid_https_url $'https://exa\u3000mple.com/path' \
    || helm_valid_https_url 'https://example.com/<appcast>' \
    || helm_valid_https_url 'https://example.com/%ZZ' \
    || helm_valid_https_url 'https://example..com/appcast.xml' \
    || helm_valid_https_url 'https://-example.com/appcast.xml' \
    || helm_valid_https_url 'https://Example.com/appcast.xml' \
    || helm_valid_https_url 'https://example.com./appcast.xml' \
    || helm_valid_https_url 'https://example.com:0443/appcast.xml' \
    || helm_valid_https_url 'https://127.1/appcast.xml' \
    || helm_valid_https_url 'https://0x7f.0x0.0x0.0x1/path' \
    || helm_valid_https_url 'https://127.0.0.0x1/path' \
    || helm_valid_https_url 'https://0177.0.0.0x1:443/path' \
    || helm_valid_https_url 'https://[2001:0db8::1]/appcast.xml'; then
    echo "FAIL: update URLs require an absolute credential-free HTTPS origin" >&2
    exit 1
fi
helm_valid_https_url 'https://127.0.0.1:443/appcast.xml'
helm_valid_https_url 'https://[2001:db8::1]:443/appcast.xml'

mkdir -p "$fixture_dir/macho-inventory/MacOS" \
    "$fixture_dir/macho-inventory/Frameworks" \
    "$fixture_dir/macho-inventory/Resources"
cp /bin/echo "$fixture_dir/macho-inventory/MacOS/Helm"
cp /bin/echo "$fixture_dir/macho-inventory/Frameworks/allowed"
allowed_macho=$'MacOS/Helm\nFrameworks/allowed'
helm_macho_inventory_matches "$fixture_dir/macho-inventory" "$allowed_macho"
cp /bin/date "$fixture_dir/macho-inventory/Resources/unexpected"
if helm_macho_inventory_matches "$fixture_dir/macho-inventory" "$allowed_macho"; then
    echo "FAIL: an unapproved Mach-O object must fail the nested inventory" >&2
    exit 1
fi

history_repo="$fixture_dir/history-repo"
mkdir -p "$history_repo/macos-app/Release"
git -C "$history_repo" init -q
git -C "$history_repo" config user.name Helm-Test
git -C "$history_repo" config user.email helm-test@example.invalid
printf '%s\n' "$latest_appcast_hash" \
    >"$history_repo/macos-app/Release/PreviousAppcast.sha256"
git -C "$history_repo" add macos-app/Release/PreviousAppcast.sha256
git -C "$history_repo" commit -qm 'Pin reviewed history'
history_commit=$(git -C "$history_repo" rev-parse HEAD)
helm_release_source_is_exact "$history_repo" "$history_commit"
if [[ $(helm_tracked_regular_file_value \
    "$history_repo" "$history_commit" \
    macos-app/Release/PreviousAppcast.sha256) != "$latest_appcast_hash" ]]; then
    echo "FAIL: the history anchor must be read from the reviewed Git commit" >&2
    exit 1
fi
printf '%s\n' "$archive_hash" \
    >"$history_repo/macos-app/Release/PreviousAppcast.sha256"
if helm_release_source_is_exact "$history_repo" "$history_commit" \
    || helm_tracked_regular_file_value \
        "$history_repo" "$history_commit" \
        macos-app/Release/PreviousAppcast.sha256 >/dev/null; then
    echo "FAIL: a post-review history-anchor rewrite must fail closed" >&2
    exit 1
fi

fake_tools="$fixture_dir/fake-tools"
fake_marker="$fixture_dir/fake-tool-executed"
mkdir -p "$fake_tools"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'touch "$HELM_FAKE_TOOL_MARKER"' \
    'printf "fake-public-key\n"' >"$fake_tools/generate_keys"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'touch "$HELM_FAKE_TOOL_MARKER"' \
    'exit 0' >"$fake_tools/sign_update"
chmod +x "$fake_tools/generate_keys" "$fake_tools/sign_update"
set +e
HELM_SPARKLE_TOOLS_DIR="$fake_tools" \
HELM_SPARKLE_KEY_ACCOUNT=fake \
HELM_FAKE_TOOL_MARKER="$fake_marker" \
    "$test_dir/../scripts/verify-release-artifact.sh" \
    /Applications/Definitely-Missing-Helm.app >/dev/null 2>&1
set -e
if [[ -e $fake_marker ]]; then
    echo "FAIL: a caller-selected Sparkle verification executable was run" >&2
    exit 1
fi

echo "RELEASE_SECURITY_TESTS=PASS"

#!/usr/bin/env bash

HELM_TREE_COMPARISON_CLEANUP_FAILED=false

helm_valid_team_id() {
    [[ ${1:-} =~ ^[A-Z0-9]{10}$ ]]
}

helm_valid_identity_sha1() {
    [[ ${1:-} =~ ^[0-9A-Fa-f]{40}$ ]]
}

helm_valid_sha256() {
    [[ ${1:-} =~ ^[0-9A-Fa-f]{64}$ ]]
}

helm_sha256_matches() {
    local file=${1:-}
    local expected=${2:-}
    local actual
    local expected_lower
    [[ -f $file ]] || return 1
    helm_valid_sha256 "$expected" || return 1
    actual=$(shasum -a 256 "$file" 2>/dev/null | awk '{print $1}') || return 1
    expected_lower=$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')
    [[ $actual == "$expected_lower" ]]
}

helm_snapshot_regular_file() {
    local source=${1:-}
    local destination=${2:-}
    local destination_parent

    [[ -f $source && ! -L $source && -n $destination \
        && ! -e $destination && ! -L $destination ]] || return 1
    destination_parent=$(dirname "$destination") || return 1
    [[ -d $destination_parent && ! -L $destination_parent ]] || return 1
    /usr/bin/ditto "$source" "$destination" >/dev/null 2>&1 || return 1
    [[ -f $destination && ! -L $destination ]]
}

helm_mount_readonly_dmg() {
    local archive=${1:-}
    local mount_point=${2:-}

    [[ -f $archive && ! -L $archive && -d $mount_point \
        && ! -L $mount_point ]] || return 1
    [[ -z $(find "$mount_point" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) ]] \
        || return 1
    /usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$mount_point" \
        "$archive" >/dev/null 2>&1
}

helm_unmount_dmg() {
    local mount_point=${1:-}
    [[ -n $mount_point && -d $mount_point ]] || return 1
    /usr/bin/hdiutil detach "$mount_point" -quiet >/dev/null 2>&1
}

helm_identity_record_matches() {
    local output=${1:-}
    local expected_sha1=${2:-}
    local expected_team=${3:-}
    local expected_sha1_upper

    helm_valid_identity_sha1 "$expected_sha1" || return 1
    helm_valid_team_id "$expected_team" || return 1
    expected_sha1_upper=$(printf '%s' "$expected_sha1" | tr '[:lower:]' '[:upper:]')

    printf '%s\n' "$output" | awk \
        -v sha1="$expected_sha1_upper" \
        -v team="$expected_team" '
        BEGIN {
            matches = 0
            identity_prefix = "^[[:space:]]*[0-9]+\\)[[:space:]]+" sha1 \
                "[[:space:]]+\"DEVELOPER ID APPLICATION:"
            identity_suffix = "\\(" team "\\)\"[[:space:]]*$"
        }
        {
            line = toupper($0)
            if (line ~ identity_prefix && line ~ identity_suffix) {
                matches++
            }
        }
        END { exit(matches == 1 ? 0 : 1) }
    '
}

helm_certificate_record_matches() {
    local output=${1:-}
    local expected_sha1=${2:-}
    local expected_sha256=${3:-}
    local expected_team=${4:-}
    local expected_sha1_upper
    local expected_sha256_upper

    helm_valid_identity_sha1 "$expected_sha1" || return 1
    helm_valid_sha256 "$expected_sha256" || return 1
    helm_valid_team_id "$expected_team" || return 1
    expected_sha1_upper=$(printf '%s' "$expected_sha1" | tr '[:lower:]' '[:upper:]')
    expected_sha256_upper=$(printf '%s' "$expected_sha256" | tr '[:lower:]' '[:upper:]')

    printf '%s\n' "$output" | awk \
        -v sha1="$expected_sha1_upper" \
        -v sha256="$expected_sha256_upper" \
        -v team="$expected_team" '
        function inspect_record() {
            if (record_sha256 == "") {
                return
            }
            if (record_sha256 == sha256 \
                    && record_sha1 == sha1 \
                    && record_label_matches == 1) {
                matches++
            }
        }
        BEGIN {
            record_sha256 = ""
            record_sha1 = ""
            record_label_matches = 0
            matches = 0
            label_suffix = "\\(" team "\\)\"[[:space:]]*$"
        }
        /^SHA-256 hash:/ {
            inspect_record()
            record_sha256 = $0
            sub(/^SHA-256 hash:[[:space:]]*/, "", record_sha256)
            sub(/[[:space:]]*$/, "", record_sha256)
            record_sha256 = toupper(record_sha256)
            record_sha1 = ""
            record_label_matches = 0
            next
        }
        /^SHA-1 hash:/ {
            record_sha1 = $0
            sub(/^SHA-1 hash:[[:space:]]*/, "", record_sha1)
            sub(/[[:space:]]*$/, "", record_sha1)
            record_sha1 = toupper(record_sha1)
            next
        }
        {
            line = toupper($0)
            if (index(line, "\"LABL\"") > 0 \
                    && index(line, "=\"DEVELOPER ID APPLICATION:") > 0 \
                    && line ~ label_suffix) {
                record_label_matches = 1
            }
        }
        END {
            inspect_record()
            exit(matches == 1 ? 0 : 1)
        }
    '
}

helm_signature_layout_is_expected() {
    local root=${1:-}
    local signature_dir
    local entry
    local entry_count
    local only_entry

    [[ -d $root ]] || return 1
    while IFS= read -r -d '' signature_dir; do
        [[ -d $signature_dir && ! -L $signature_dir ]] || return 1
        entry_count=0
        only_entry=""
        while IFS= read -r -d '' entry; do
            entry_count=$((entry_count + 1))
            only_entry=$entry
        done < <(/usr/bin/find "$signature_dir" \
            -mindepth 1 -maxdepth 1 -print0)
        [[ $entry_count -eq 1 \
            && $only_entry == "$signature_dir/CodeResources" \
            && -f $only_entry && ! -L $only_entry \
            && $(/usr/bin/stat -f %l "$only_entry" 2>/dev/null) == "1" ]] \
            || return 1
    done < <(/usr/bin/find "$root" -name _CodeSignature -prune -print0)
}

helm_remove_expected_signature_artifacts() {
    local root=${1:-}
    local signature_dir

    helm_signature_layout_is_expected "$root" || return 1
    while IFS= read -r -d '' signature_dir; do
        /bin/rm -f -- "$signature_dir/CodeResources" || return 1
        /bin/rmdir -- "$signature_dir" || return 1
    done < <(/usr/bin/find "$root" -type d -name _CodeSignature \
        -prune -print0)
}

helm_strip_code_signatures_from_tree() {
    local root=${1:-}
    local item

    [[ -d $root ]] || return 1
    helm_remove_expected_signature_artifacts "$root" || return 1
    while IFS= read -r -d '' item; do
        if /usr/bin/file -b "$item" 2>/dev/null | grep -q 'Mach-O'; then
            codesign --remove-signature "$item" >/dev/null 2>&1 || return 1
        fi
    done < <(/usr/bin/find "$root" -type f -print0)
}

helm_tree_manifest() {
    local root=${1:-}
    local library_dir
    local manifest_script

    [[ -d $root && ! -L $root && -x /usr/bin/python3 ]] || return 1
    library_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || return 1
    manifest_script="$library_dir/release-tree-manifest.py"
    [[ -f $manifest_script && ! -L $manifest_script ]] || return 1
    /usr/bin/python3 "$manifest_script" "$root"
}

helm_trees_match_without_signatures() {
    local source_tree=${1:-}
    local candidate_tree=${2:-}
    local work
    local result=1

    [[ -d $source_tree && ! -L $source_tree \
        && -d $candidate_tree && ! -L $candidate_tree ]] || return 1
    work=$(mktemp -d /tmp/helm-signature-normalize.XXXXXX) || return 1

    if helm_signature_layout_is_expected "$source_tree" \
        && helm_signature_layout_is_expected "$candidate_tree" \
        && helm_tree_manifest "$source_tree" >/dev/null \
        && helm_tree_manifest "$candidate_tree" >/dev/null \
        && ditto "$source_tree" "$work/source" >/dev/null 2>&1 \
        && ditto "$candidate_tree" "$work/candidate" >/dev/null 2>&1 \
        && helm_strip_code_signatures_from_tree "$work/source" \
        && helm_strip_code_signatures_from_tree "$work/candidate" \
        && helm_tree_manifest "$work/source" >"$work/source.manifest" \
        && helm_tree_manifest "$work/candidate" >"$work/candidate.manifest" \
        && diff -q "$work/source.manifest" \
            "$work/candidate.manifest" >/dev/null 2>&1; then
        result=0
    fi

    if ! /bin/rm -rf -- "$work" || [[ -e $work || -L $work ]]; then
        HELM_TREE_COMPARISON_CLEANUP_FAILED=true
        return 3
    fi
    return "$result"
}

helm_zip_entries_are_scoped() {
    local archive=${1:-}
    local root=${2:-}
    local entries
    local entry
    local path

    [[ -f $archive && $root =~ ^[^/\\]+$ ]] || return 1
    entries=$(zipinfo -1 "$archive" 2>/dev/null) || return 1
    [[ -n $entries ]] || return 1

    while IFS= read -r entry; do
        [[ -n $entry && $entry != /* && $entry != *\\* ]] || return 1
        case "$entry" in
            "$root"|"$root/"|"$root/"*) ;;
            *) return 1 ;;
        esac

        path=${entry%/}
        case "/$path/" in
            *"/../"*|*"/./"*|*"//"*) return 1 ;;
        esac
    done <<<"$entries"
}

helm_tree_symlinks_are_internal() {
    local root=${1:-}
    local root_absolute
    local link
    local target
    local resolved

    [[ -d $root && ! -L $root ]] || return 1
    root_absolute=$(realpath "$root" 2>/dev/null) || return 1

    while IFS= read -r -d '' link; do
        target=$(readlink "$link" 2>/dev/null) || return 1
        [[ $target != /* ]] || return 1
        resolved=$(realpath "$link" 2>/dev/null) || return 1
        case "$resolved" in
            "$root_absolute"|"$root_absolute/"*) ;;
            *) return 1 ;;
        esac
    done < <(find "$root" -type l -print0)
}

helm_macho_inventory_matches() {
    local root=${1:-}
    local expected=${2:-}
    local file
    local relative
    local actual=""
    local actual_sorted
    local expected_sorted

    [[ -d $root ]] || return 1
    while IFS= read -r -d '' file; do
        if /usr/bin/file -b "$file" 2>/dev/null | grep -q 'Mach-O'; then
            relative=${file#"$root"/}
            [[ -n $relative && $relative != "$file" \
                && $relative != *$'\n'* && $relative != *$'\r'* ]] || return 1
            actual="${actual}${relative}"$'\n'
        fi
    done < <(find "$root" -type f -print0)

    actual_sorted=$(printf '%s' "$actual" | sed '/^$/d' | LC_ALL=C sort) || return 1
    expected_sorted=$(printf '%s\n' "$expected" | sed '/^$/d' | LC_ALL=C sort) || return 1
    [[ -n $expected_sorted && $actual_sorted == "$expected_sorted" ]]
}

helm_valid_https_url() {
    local value=${1:-}
    [[ -n $value && -x /usr/bin/python3 ]] || return 1

    /usr/bin/python3 - "$value" <<'PY'
import sys
import ipaddress
import re
import socket
from urllib.parse import urlsplit

value = sys.argv[1]
try:
    value.encode("ascii")
except UnicodeEncodeError:
    raise SystemExit(1)
if any(ord(character) < 0x21 or ord(character) > 0x7E for character in value):
    raise SystemExit(1)
if any(character in value for character in '\\#<>"{}|^`'):
    raise SystemExit(1)
if re.search(r"%(?![0-9A-Fa-f]{2})", value):
    raise SystemExit(1)
try:
    parsed = urlsplit(value)
    port = parsed.port
except ValueError:
    raise SystemExit(1)
if parsed.scheme.lower() != "https" or not parsed.netloc or not parsed.hostname:
    raise SystemExit(1)
if parsed.username is not None or parsed.password is not None or "@" in parsed.netloc:
    raise SystemExit(1)
if port is not None and port < 1:
    raise SystemExit(1)
if "[" in parsed.path or "]" in parsed.path or "[" in parsed.query or "]" in parsed.query:
    raise SystemExit(1)

authority = parsed.netloc
if authority.startswith("["):
    match = re.fullmatch(r"\[([0-9A-Fa-f:.]+)\](?::([0-9]+))?", authority)
    if match is None:
        raise SystemExit(1)
    try:
        address = ipaddress.IPv6Address(match.group(1))
    except ipaddress.AddressValueError:
        raise SystemExit(1)
    if match.group(1) != address.compressed:
        raise SystemExit(1)
    raw_port = match.group(2)
else:
    match = re.fullmatch(r"([^:]+)(?::([0-9]+))?", authority)
    if match is None:
        raise SystemExit(1)
    raw_host = match.group(1)
    raw_port = match.group(2)
    if raw_host != raw_host.lower() or raw_host.endswith("."):
        raise SystemExit(1)
    try:
        address = ipaddress.ip_address(raw_host)
    except ValueError:
        try:
            socket.inet_aton(raw_host)
        except OSError:
            pass
        else:
            raise SystemExit(1)
        labels = raw_host.split(".")
        if len(raw_host) > 253 or len(labels) < 2 or labels[-1].isdigit():
            raise SystemExit(1)
        label_pattern = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?")
        if any(label_pattern.fullmatch(label) is None for label in labels):
            raise SystemExit(1)
    else:
        if not isinstance(address, ipaddress.IPv4Address) or raw_host != str(address):
            raise SystemExit(1)

if parsed.hostname != (address.compressed if authority.startswith("[") else raw_host):
    raise SystemExit(1)
if raw_port is not None and (port is None or raw_port != str(port)):
    raise SystemExit(1)
PY
}

helm_decimal_gt() {
    local left=${1:-}
    local right=${2:-}

    [[ $left =~ ^[0-9]+$ && $right =~ ^[0-9]+$ ]] || return 1
    left=$(printf '%s' "$left" | sed 's/^0*//')
    right=$(printf '%s' "$right" | sed 's/^0*//')
    [[ -n $left ]] || left=0
    [[ -n $right ]] || right=0

    if [[ ${#left} -ne ${#right} ]]; then
        [[ ${#left} -gt ${#right} ]]
        return
    fi
    [[ $left > $right ]]
}

helm_appcast_max_build() {
    local appcast=${1:-}
    local count
    local index
    local value
    local maximum=""
    local sparkle_namespace='http://www.andymatuschak.org/xml-namespaces/sparkle'
    local enclosure_xpath="//*[local-name()='enclosure' and namespace-uri()='']"

    [[ -f $appcast ]] || return 1
    count=$(xmllint --nonet --xpath \
        "count($enclosure_xpath/@*[local-name()='version' and namespace-uri()='$sparkle_namespace'])" \
        "$appcast" 2>/dev/null) || return 1
    [[ $count =~ ^[1-9][0-9]*$ ]] || return 1

    index=1
    while [[ $index -le $count ]]; do
        value=$(xmllint --nonet --xpath \
            "string(($enclosure_xpath/@*[local-name()='version' and namespace-uri()='$sparkle_namespace'])[$index])" \
            "$appcast" 2>/dev/null) || return 1
        [[ $value =~ ^(0|[1-9][0-9]*)$ ]] || return 1
        if [[ -z $maximum ]] || helm_decimal_gt "$value" "$maximum"; then
            maximum=$value
        fi
        index=$((index + 1))
    done

    printf '%s\n' "$maximum"
}

helm_appcast_has_only_canonical_sparkle_attributes() {
    local appcast=${1:-}
    local conflicts
    local sparkle_namespace='http://www.andymatuschak.org/xml-namespaces/sparkle'
    local enclosure_xpath="//*[local-name()='enclosure' and namespace-uri()='']"

    [[ -f $appcast ]] || return 1
    conflicts=$(xmllint --nonet --xpath \
        "count($enclosure_xpath/@*[(local-name()='version' or local-name()='edSignature') and namespace-uri()!='$sparkle_namespace'])" \
        "$appcast" 2>/dev/null) || return 1
    [[ $conflicts == "0" ]]
}

helm_valid_git_commit() {
    [[ ${1:-} =~ ^([0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$ ]]
}

helm_release_source_is_exact() {
    local project_root=${1:-}
    local expected_commit=${2:-}
    local head_commit
    local resolved_expected

    [[ -d $project_root ]] || return 1
    helm_valid_git_commit "$expected_commit" || return 1
    head_commit=$(git -C "$project_root" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) \
        || return 1
    resolved_expected=$(git -C "$project_root" rev-parse --verify \
        "$expected_commit^{commit}" 2>/dev/null) || return 1
    [[ $head_commit == "$resolved_expected" ]] || return 1
    [[ -z $(git -C "$project_root" status --porcelain --untracked-files=all) ]]
}

helm_tracked_regular_file_value() {
    local project_root=${1:-}
    local expected_commit=${2:-}
    local relative_path=${3:-}
    local tree_entry
    local mode
    local committed_value
    local working_value

    helm_release_source_is_exact "$project_root" "$expected_commit" || return 1
    [[ $relative_path =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ \
        && $relative_path != /* \
        && "/$relative_path/" != *"/../"* \
        && "/$relative_path/" != *"/./"* \
        && -f $project_root/$relative_path \
        && ! -L $project_root/$relative_path ]] || return 1

    tree_entry=$(git -C "$project_root" ls-tree "$expected_commit" -- \
        "$relative_path" 2>/dev/null) || return 1
    mode=$(printf '%s\n' "$tree_entry" | awk 'NR == 1 { print $1 }')
    [[ $mode == "100644" || $mode == "100755" ]] || return 1
    [[ $(printf '%s\n' "$tree_entry" | wc -l | tr -d '[:space:]') == "1" ]] \
        || return 1
    git -C "$project_root" diff --quiet "$expected_commit" -- \
        "$relative_path" || return 1
    committed_value=$(git -C "$project_root" show \
        "$expected_commit:$relative_path" 2>/dev/null) || return 1
    working_value=$(<"$project_root/$relative_path") || return 1
    [[ $working_value == "$committed_value" ]] || return 1
    printf '%s\n' "$committed_value"
}

helm_entitlements_are_exact() {
    local file=${1:-}
    local canonical
    [[ -f $file ]] || return 1
    canonical=$(plutil -convert json -o - "$file" 2>/dev/null) || return 1
    [[ $canonical == '{"com.apple.security.device.audio-input":true}' ]]
}

helm_entitlements_are_empty() {
    local file=${1:-}
    local canonical
    [[ -f $file ]] || return 1
    canonical=$(plutil -convert json -o - "$file" 2>/dev/null) || return 1
    [[ $canonical == '{}' ]]
}

helm_bundle_value() {
    local plist=${1:-}
    local key=${2:-}
    /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null
}

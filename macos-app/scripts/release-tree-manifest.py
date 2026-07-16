#!/usr/bin/env python3

import base64
import hashlib
import os
import re
import stat
import subprocess
import sys


# macOS-generated values observed across the pinned inputs and system apps use
# a fixed three-byte header followed by a nonzero opaque 64-bit lineage ID.
PROVENANCE_HEX_PREFIX = "010200"
PROVENANCE_LINEAGE_HEX_LENGTH = 16
ALLOWED_XATTRS = frozenset({"com.apple.provenance"})
ENVIRONMENT = os.environ.copy()
ENVIRONMENT["LC_ALL"] = "C"


def encoded(value):
    return base64.b64encode(os.fsencode(value)).decode("ascii")


def provenance_hex_is_allowed(value):
    normalized = "".join(value.split()).lower()
    expected_length = len(PROVENANCE_HEX_PREFIX) + PROVENANCE_LINEAGE_HEX_LENGTH
    if len(normalized) != expected_length or re.fullmatch(r"[0-9a-f]+", normalized) is None:
        return False
    if not normalized.startswith(PROVENANCE_HEX_PREFIX):
        return False
    lineage = normalized[len(PROVENANCE_HEX_PREFIX) :]
    return int(lineage, 16) != 0


def validate_metadata(path, metadata):
    if getattr(metadata, "st_flags", 0) != 0:
        raise ValueError("file flags are not allowed")

    acl = subprocess.run(
        ["/bin/ls", "-lde", path],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        env=ENVIRONMENT,
        check=False,
    )
    if acl.returncode != 0 or not acl.stdout:
        raise ValueError("metadata could not be read")
    permission_token = acl.stdout.split(None, 1)[0]
    acl_entries = acl.stdout.splitlines()[1:]
    if "+" in permission_token or any(
        re.match(r"^\s*[0-9]+:", line) for line in acl_entries
    ):
        raise ValueError("ACLs are not allowed")

    xattr_command = ["/usr/bin/xattr"]
    if stat.S_ISLNK(metadata.st_mode):
        xattr_command.append("-s")
    xattr_command.append(path)
    xattr_result = subprocess.run(
        xattr_command,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        env=ENVIRONMENT,
        check=False,
    )
    if xattr_result.returncode != 0:
        raise ValueError("extended attributes could not be read")
    xattrs = set(filter(None, xattr_result.stdout.splitlines()))
    if not xattrs.issubset(ALLOWED_XATTRS):
        raise ValueError("an extended attribute is not allowed")

    if "com.apple.provenance" in xattrs:
        provenance_command = ["/usr/bin/xattr", "-p", "-x"]
        if stat.S_ISLNK(metadata.st_mode):
            provenance_command.append("-s")
        provenance_command.extend(["com.apple.provenance", path])
        provenance_result = subprocess.run(
            provenance_command,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            env=ENVIRONMENT,
            check=False,
        )
        if provenance_result.returncode != 0 or not provenance_hex_is_allowed(
            provenance_result.stdout
        ):
            raise ValueError("provenance encoding is not allowed")


def emit(path, relative):
    metadata = os.lstat(path)
    if not (
        stat.S_ISDIR(metadata.st_mode)
        or stat.S_ISREG(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
    ):
        raise ValueError("unsupported filesystem object")
    validate_metadata(path, metadata)
    mode = format(stat.S_IMODE(metadata.st_mode), "04o")
    relative_field = encoded(relative)

    if stat.S_ISDIR(metadata.st_mode):
        print(f"D\t{mode}\t{relative_field}\t-")
        with os.scandir(path) as iterator:
            children = sorted(iterator, key=lambda entry: os.fsencode(entry.name))
        for child in children:
            child_relative = (
                child.name if relative == "." else f"{relative}/{child.name}"
            )
            emit(child.path, child_relative)
        return

    if stat.S_ISREG(metadata.st_mode):
        if metadata.st_nlink != 1:
            raise ValueError("regular-file hard links are not allowed")
        digest = hashlib.sha256()
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        print(f"F\t{mode}\t{relative_field}\t{digest.hexdigest()}")
        return

    if stat.S_ISLNK(metadata.st_mode):
        if metadata.st_nlink != 1:
            raise ValueError("symlink hard links are not allowed")
        print(f"L\t{mode}\t{relative_field}\t{encoded(os.readlink(path))}")
        return

    raise ValueError("unreachable filesystem object type")


def main(argv):
    if len(argv) != 2:
        return 2
    root = os.path.abspath(argv[1])
    try:
        root_metadata = os.lstat(root)
        if not stat.S_ISDIR(root_metadata.st_mode):
            return 1
        emit(root, ".")
    except (OSError, UnicodeError, ValueError):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

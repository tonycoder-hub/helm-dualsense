# Pinned runtimes

## SDL3

The local build uses the official SDL 3.4.12 macOS framework from:

`https://github.com/libsdl-org/SDL/releases/download/release-3.4.12/SDL3-3.4.12.dmg`

Pinned SHA-256 (`SDL.sha256`):

`c77d36d9393bb5481e38d222b75a1a63ab16274457b3d18c63fef90aaf5fc93b`

The macOS framework lives at
`SDL3.xcframework/macos-arm64_x86_64/SDL3.framework` inside the DMG and is copied
into `macos-app/.vendor/SDL3.framework` locally. The framework is not committed.
Formal preflight snapshots the caller's regular-file DMG, checks the machine
pin, mounts it read-only, and compares the vendor tree after signature
normalization. Final verification repeats that comparison against the embedded,
release-signed framework. `build-and-install.sh` embeds it in `GripPilot.app`.
SDL uses the zlib license; the official `LICENSE.txt` is copied into the app
resources.

The normalized comparison is manifest-based: path, type, mode, symlink target,
and file SHA-256 must match. ACLs, file flags, hard links, unexpected xattrs,
and extra `_CodeSignature` payloads fail closed; only the platform-generated
`com.apple.provenance` xattr is ignored.

## Sparkle

Formal update preparation uses the official Sparkle 2.9.4 distribution from:

`https://github.com/sparkle-project/Sparkle/releases/download/2.9.4/Sparkle-2.9.4.tar.xz`

Pinned SHA-256:

`ce89daf967db1e1893ed3ebd67575ed82d3902563e3191ca92aaec9164fbdef9`

The archive is verified before `Sparkle.framework` is copied into the ignored
`macos-app/.vendor` directory. `release-preflight.sh` rechecks the archive hash,
framework contents, Apple code signature, version, arm64 slice, build linkage,
and signed-feed configuration. The updater remains disabled in the Demo because
no production feed or public key has been configured. Sparkle uses the MIT
license; its distribution `LICENSE` is embedded in the app resources.

# SDL3 runtime

The local build uses the official SDL 3.4.12 macOS framework from:

`https://github.com/libsdl-org/SDL/releases/download/release-3.4.12/SDL3-3.4.12.dmg`

Observed SHA-256:

`c77d36d9393bb5481e38d222b75a1a63ab16274457b3d18c63fef90aaf5fc93b`

The framework is copied into `macos-app/.vendor/SDL3.framework` locally and is
not committed. `build-and-install.sh` embeds it in `Helm Demo.app`. SDL uses the
zlib license; the official `LICENSE.txt` is copied into the app resources.

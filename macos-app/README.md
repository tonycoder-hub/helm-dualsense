# Helm Demo for macOS

This is the local SwiftUI demo for controlling macOS with a DualSense. It uses
SDL3 for the dedicated microphone button and touch contacts, CoreGraphics for
pointer/click/scroll output, and AVFoundation + Apple Speech for push-to-talk
transcription. The SDL bridge accepts only PS5-class controllers, so an Xbox or
generic gamepad cannot be selected accidentally.

## Try it

1. Open `~/Applications/Helm Demo.app`.
2. Connect the DualSense by USB-C for the first test. Bluetooth can follow;
   SDL enhanced reports stay in `auto` mode to avoid forcing a persistent
   controller report-mode change before the app actually needs it.
3. In Helm, grant Accessibility, Microphone, and Speech Recognition only when
   you are ready to test them.
4. Click **Enable Controls**. The app always starts disabled.
5. Use the left stick for the main pointer, the touchpad for precision, and
   Cross/Circle for click or hold-to-drag. The right stick scrolls, D-pad pages,
   and the microphone button controls PTT. L2 brakes pointer/scroll speed and R2
   accelerates it.
6. Hold Options, then press the touchpad button within two seconds to use the
   emergency enable/disable gesture.

The control center can remap Cross, Circle, Create, D-pad up/down, and the
microphone button, including three configurable keyboard-shortcut actions for
external input methods. It also exposes the input polling rate, a smooth
hold-to-accelerate curve, and racing-style L2/R2 speed multipliers. These
settings persist locally.

Semantic haptics are optional and off by default. When enabled, short tuned
pulses acknowledge clicks, navigation, shortcuts, and PTT state changes; normal
pointer movement and scrolling remain silent. Use **Test Haptics** after SDL
reports rumble capability, then tune the master intensity. USB and Bluetooth
feel still require separate real-controller validation.

The **Hold to Test** control lets you test microphone selection and speech
recognition without a controller, then returns to the last external foreground
application before committing text. If that focus cannot be restored and
confirmed within 0.5 seconds, transcription is retained in Helm and automatic
insertion is suppressed. Text insertion first uses the focused
Accessibility element and falls back to Unicode keyboard events for supported
editable roles. Unicode event delivery is shown as unconfirmed because a target
application may ignore it. Secure fields and system secure-input mode are
refused. It never uses the clipboard as a hidden fallback.

Sony does not support the DualSense built-in microphone as a Mac audio input.
The controller microphone button controls PTT; the visible microphone picker
selects the actual Mac-supported input source.
Playback protection is on by default and avoids Bluetooth microphone inputs so
AirPods or another Bluetooth output does not switch into its call profile;
choose a built-in/USB microphone, or explicitly disable the protection.
Enabling protection during Bluetooth capture cancels the active PTT session
before changing the selected input.

## Build locally

The checked-out official SDL framework must be present at
`macos-app/.vendor/SDL3.framework`, and the verified Sparkle 2.9.4 framework at
`macos-app/.vendor/Sparkle.framework`. See `ThirdParty/README.md` for the pinned
URLs and checksums. Then run:

```bash
macos-app/scripts/build-and-install.sh --launch
```

The script runs the pure mapping tests, builds with the installed Command Line
Tools, embeds SDL3 and inactive pinned Sparkle, applies an ad-hoc signature,
verifies the bundle, preserves the previous installation only while replacement
is in progress, and keeps one
installed copy in `~/Applications`.

This development installer cannot create a public release. The separate
fail-closed readiness check is:

```bash
HELM_SDL_ARCHIVE=/tmp/SDL3-3.4.12.dmg \
HELM_SPARKLE_ARCHIVE=/tmp/Sparkle-2.9.4.tar.xz \
  macos-app/scripts/release-preflight.sh
```

Developer ID signing, notarization, and signed Sparkle updates remain blocked
until every reported gate passes.

Formal preflight and final verification also require
`HELM_RELEASE_SOURCE_COMMIT` to be the full hash of the same reviewed, clean
`HEAD`. The history anchor is read from that Git commit, not trusted from a
mutable working-tree value.

Both dependency inputs are snapshotted before use. SDL is bound to the tracked
version and DMG SHA-256, then its macOS framework is compared after signature
normalization during preflight and final artifact verification. The final
Mach-O inventory covers the entire `Helm.app/Contents` tree and allows only the
main executable plus the six expected SDL/Sparkle objects.
Signature-normalized framework comparison also binds path, type, mode, symlink
target, and file hashes, while rejecting unexpected signature payloads, ACLs,
file flags, hard links, and non-platform xattrs.

Formal feed and enclosure URLs must also pass the canonical HTTPS profile:
printable ASCII, a lowercase validated DNS name or canonical IP literal, no
credentials or fragment, and no whitespace, forbidden raw delimiters, or
malformed percent escape. The release scripts report these as explicit gates.

The Demo intentionally omits `SUFeedURL` and `SUPublicEDKey`. Its visible update
status therefore remains disabled and it never contacts a placeholder feed.
After a formal artifact is produced, verify it with the ZIP, current signed
appcast, and the exact prior signed appcast archived with the preceding
immutable release:

```bash
macos-app/scripts/verify-release-artifact.sh \
  /path/to/Helm.app \
  /path/to/Helm-version-macOS-arm64.zip \
  /path/to/appcast.xml \
  /path/to/previous-signed-appcast.xml
```

For the first formal release, the last argument is the reviewed, offline,
EdDSA-signed genesis appcast whose only build is `0`. A raw previous-build
number is intentionally unsupported. Its exact SHA-256 must already be pinned
in `Release/PreviousAppcast.sha256`; the committed `UNCONFIGURED` sentinel keeps
formal release checks blocked until that reviewed key-ceremony step is complete.

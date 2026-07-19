# Helm Demo for macOS

This is the local SwiftUI demo for controlling macOS with PlayStation, Xbox,
and Nintendo controllers. It uses SDL3 for buttons, paddles and touch contacts,
CoreGraphics for pointer/click/scroll output, and AVFoundation + Apple Speech
for push-to-talk transcription.

## Try it

1. Open `~/Applications/Helm Demo.app`.
2. Connect the DualSense by USB-C for the first test. Bluetooth can follow;
   SDL enhanced reports stay in `auto` mode to avoid forcing a persistent
   controller report-mode change before the app actually needs it.
3. In Helm, grant Accessibility, Microphone, and Speech Recognition only when
   you are ready to test them.
4. If the controller was already connected when Helm launched, controls enable
   automatically by default after Accessibility is available. Turn off the
   launch toggle if you prefer an explicit **Enable Controls** click.
5. Use the left stick for the main pointer, the touchpad for precision, and
   Cross/Circle for click or hold-to-drag. The right stick scrolls, D-pad pages,
   and the microphone button controls PTT. L2 brakes pointer/scroll speed and R2
   accelerates it.
6. Press Options and the touchpad button within two seconds, in either order,
   to emergency-stop controls. This gesture never enables controls.

The control center records any supported single button or combination of up to
four buttons, including SDL's four professional-controller paddle positions.
Mappings include three configurable keyboard-shortcut actions for external
input methods, including held Command/Control/Option/Shift-only mappings with
independent left/right physical modifier selection. Mapping capture suppresses
desktop injection while recording but keeps the controller and enabled control
session connected.
The current analog state is actively sampled at a fixed 240 Hz instead of
relying on per-axis SDL event frequency.
The default curve now uses a low-latency radial response floor and 6 ms
smoothing; fractional continuous-pixel scrolling accumulates into evenly
spaced symmetric point events without a startup spike. The response, smoothing, smooth
hold-to-accelerate curve, and racing-style trigger speed multipliers remain
configurable and are persisted locally.

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
Accessibility element and falls back to Unicode keyboard events only after the
focused element PID matches the process identity captured at PTT start,
including web
editors that expose generic AX roles. The physical PTT path keeps that captured
target for the whole recognition session, revalidates it immediately before
delivery, then uses a global HID Unicode event so web/Electron editors receive
the same route as normal keyboard input.
If UI PTT could not capture an AX element while Helm was frontmost, completion
reactivates the exact original process and recaptures its current focused text
element; it never substitutes another process or replaces a valid earlier
snapshot.
Unicode event delivery is shown as unconfirmed because a target
application may ignore it. Secure fields and system secure-input mode are
refused. It never uses the clipboard as a hidden fallback.
If a completed transcript remains in Helm, activate the intended external text
field again and then use **重新发送到外部焦点**. This explicit recovery path
consumes that post-recognition activation, validates both the target PID and
process launch time on every retry, uses the same secure-input checks, waits for
any automatic delivery to finish, and does not capture audio again.

The target Mac currently exposes a wired DualSense as a 48 kHz USB audio input.
When that route briefly re-enumerates the controller HID while PTT starts, Helm
releases held pointer actions immediately but preserves recognition for a
bounded same-controller reconnect. The visible microphone picker remains the
source of truth; Bluetooth controller audio is not treated as a music-safe
input route. Controller PTT is independent of the desktop-control switch, so
the target application can retain focus while mouse injection remains off.
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

The script runs the pure mapping tests and an isolated SDL virtual-gamepad
analog-read integration test, builds with the installed Command Line Tools,
embeds SDL3 and pinned Sparkle, applies an ad-hoc signature with
a stable local designated requirement, verifies the bundle, preserves the
top-level app directory while transactionally replacing only its `Contents`,
and keeps one installed copy in `~/Applications`. The first migration from an older ad-hoc
identity can require one final permission grant; later in-place local builds
retain the same requirement. On the target Mac, six updates from build 11
through build 17 changed CDHash each time while preserving the app inode and
requirement, and all three privacy statuses remained authorized after every
relaunch. Formal releases do not use this local identity, so that result must
not be generalized to Developer ID distribution.

The manual GitHub **Release** workflow creates the public Demo ZIP, signed
Sparkle appcast, and portable SHA-256 manifest from `main`. It verifies the
latest signed appcast and refuses a non-increasing build number. It uses a
dedicated protected `release` environment and its environment-scoped signing secret. This public
Demo remains ad-hoc signed and is separate from the fail-closed formal readiness
check:

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

The Demo includes `SUFeedURL`, `SUPublicEDKey`, signed-feed enforcement,
pre-extraction verification, and non-expiring signature failures for the GitHub
Releases channel. Automatic background checks remain disabled;
users initiate checks explicitly in Helm. Before the first GitHub Release is
published, the stable `latest` feed URL can return no feed.
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

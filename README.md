# Helm

Helm is an experimental macOS control center that turns a Sony DualSense into
one compact desktop controller.

![Helm DualSense control center](docs/reviews/helm-ui-preview.png)

## Controls

| DualSense input | macOS action |
| --- | --- |
| Left stick | Main pointer movement |
| Touchpad | Precision pointer movement |
| Cross | Left click / hold to drag |
| Circle | Right click / hold to drag |
| Right stick up/down | Smooth scrolling |
| L2 / R2 | Brake / accelerate pointer and scrolling |
| D-pad up/down | Page navigation |
| Microphone button | Push to talk |
| Hold Options, then press touchpad within two seconds | Enable / emergency stop |

Pointer speed is adjustable in the app. The left stick uses a radial dead zone
and nonlinear acceleration that ramps up while held, while touchpad movement is
deliberately slower and capped for precision. The acceleration duration and
maximum boost are configurable and shown as a live curve.

Cross, Circle, Create, D-pad up/down, and the microphone button can each be
mapped to left click, right click, page up/down, PTT, one of three configurable
keyboard shortcuts, or no action. The shortcut slots can invoke an external
input method without bringing Helm to the foreground. Mappings and motion
settings persist across launches. The safety chord is intentionally fixed and
cannot be remapped.

L2 acts like a racing-game brake and R2 acts like an accelerator. Their minimum
and maximum multipliers are configurable and apply to left-stick/touchpad
pointer movement and right-stick scrolling.

Controller polling defaults to 120 Hz and can be changed to 60, 90, 120, 144,
or 240 Hz. Pointer movement is integrated using elapsed time, so changing the
polling rate affects smoothness rather than speed.

## Haptic feedback

Optional semantic haptics acknowledge discrete actions such as clicks, page
navigation, shortcuts, and PTT start/stop. They are off by default, use a
conservative 35% initial intensity, and never run continuously for pointer or
scroll movement. Helm checks SDL's whole-gamepad rumble capability at runtime;
adaptive-trigger effects are intentionally a separate future feature. See the
[haptic design and safety policy](docs/haptics.md).

## Safety model

- Only controllers identified by SDL as PS5-class devices are accepted; Xbox
  and generic controllers are ignored.
- Controls start disabled and return to disabled after reconnect, sleep/timer
  gaps, permission loss, disconnect, or app termination.
- Accessibility, Microphone, and Speech permissions are requested only after an
  explicit action in the visible UI.
- Pending Speech callbacks are cancelled on emergency stop.
- Microphone and Speech permissions are requested sequentially, and an
  interrupted on-screen PTT test is cancelled instead of remaining stuck.
- Recognized text first uses the focused Accessibility text element, then uses
  Unicode keyboard events for supported editable fields that reject direct AX
  insertion. Secure Input and secure text fields are refused; the clipboard is
  never used as a fallback. Direct AX insertion is reported as confirmed;
  Unicode event delivery is explicitly reported as unconfirmed because the
  target application may ignore it.

## Voice limitation

The DualSense microphone button is used as the PTT control. Audio is captured
from the macOS-supported input explicitly selected in Helm. The app does not
claim that the controller's built-in microphone is available as a Mac input.

Playback protection is enabled by default. If the system default input is a
Bluetooth headset microphone, Helm selects a built-in or USB input instead;
opening a classic Bluetooth microphone can switch the headset into its call
profile and interrupt or degrade music. The protection can be disabled
explicitly when that tradeoff is desired. Enabling protection during an active
Bluetooth capture immediately cancels that capture before switching the picker.

## Requirements

- macOS 14 or later
- Apple Command Line Tools or Xcode
- A DualSense or DualSense Edge
- SDL3 3.4.12 macOS framework
- Sparkle 2.9.4 macOS framework (pinned but inactive until the formal feed is configured)

The current Demo is ad-hoc signed for local development. Real controller,
Accessibility, and speech behavior should be validated on the target Mac before
relying on it for everyday use.

Formal Developer ID signing, notarization, and signed Sparkle updates are
fail-closed preparation work, not current Demo capabilities. See the
[release and update contract](docs/release-and-updates.md) and run
`macos-app/scripts/release-preflight.sh` to see the remaining gates.

## Build and install

Download the official SDL3 macOS framework, verify it, and place it in the
ignored local vendor directory:

```bash
curl -L \
  -o /tmp/SDL3-3.4.12.dmg \
  https://github.com/libsdl-org/SDL/releases/download/release-3.4.12/SDL3-3.4.12.dmg

echo "c77d36d9393bb5481e38d222b75a1a63ab16274457b3d18c63fef90aaf5fc93b  /tmp/SDL3-3.4.12.dmg" \
  | shasum -a 256 -c -

hdiutil attach /tmp/SDL3-3.4.12.dmg
mkdir -p macos-app/.vendor
ditto /Volumes/SDL3/SDL3.xcframework/macos-arm64_x86_64/SDL3.framework \
  macos-app/.vendor/SDL3.framework
hdiutil detach /Volumes/SDL3

curl -L \
  -o /tmp/Sparkle-2.9.4.tar.xz \
  https://github.com/sparkle-project/Sparkle/releases/download/2.9.4/Sparkle-2.9.4.tar.xz

echo "ce89daf967db1e1893ed3ebd67575ed82d3902563e3191ca92aaec9164fbdef9  /tmp/Sparkle-2.9.4.tar.xz" \
  | shasum -a 256 -c -

sparkle_dir=$(mktemp -d /tmp/helm-sparkle.XXXXXX)
tar -xf /tmp/Sparkle-2.9.4.tar.xz -C "$sparkle_dir"
ditto "$sparkle_dir/Sparkle.framework" macos-app/.vendor/Sparkle.framework
ditto "$sparkle_dir/LICENSE" macos-app/.vendor/Sparkle-LICENSE.txt
```

Then run:

```bash
macos-app/scripts/build-and-install.sh --launch
```

The script runs the deterministic control-math/audio tests, compiles Swift and C
with warnings treated as errors, embeds SDL3 and the pinned Sparkle framework,
applies an ad-hoc signature, and installs to `~/Applications/Helm Demo.app`. It
temporarily preserves the prior
installation during replacement, verifies the installed copy, and removes the
temporary copy after success.

The Demo has no feed URL or update public key, so its updater stays disabled and
does not contact a placeholder service. Formal release verification additionally
binds an exact Developer ID certificate and Team ID, checks both official SDL
and Sparkle archive hashes and signature-normalized embedded contents, verifies
embedded linkage and archive-sourced Sparkle tools, rejects any Mach-O outside
the exact main-plus-six-helper allowlist across the entire App Contents tree,
enforces exact main/nested entitlement policies, validates the stapled ticket, and
cryptographically verifies the ZIP and appcast against a reviewed prior-feed
SHA-256 anchor read from the same clean reviewed Git commit at preflight and
final verification.

## Privacy permissions

Helm does not request privacy permissions at launch. Use the visible permission
buttons when you are ready, complete the macOS System Settings flow, return to
Helm, and select **Refresh**.

## License

Helm source code is available under the [MIT License](LICENSE). SDL3 is a
separate dependency distributed under the zlib license; Sparkle is a separate
dependency distributed under the MIT license. Their binary frameworks are not
committed to this repository.

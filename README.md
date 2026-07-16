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
| D-pad up/down | Page navigation |
| Microphone button | Push to talk |
| Hold Options, then press touchpad within two seconds | Enable / emergency stop |

Pointer speed is adjustable in the app. The left stick uses a radial dead zone
and nonlinear acceleration that ramps up while held, while touchpad movement is
deliberately slower and capped for precision. The acceleration duration and
maximum boost are configurable and shown as a live curve.

Cross, Circle, Create, D-pad up/down, and the microphone button can each be
mapped to left click, right click, page up/down, PTT, or no action. Mappings and
motion settings persist across launches. The safety chord is intentionally
fixed and cannot be remapped.

Controller polling defaults to 120 Hz and can be changed to 60, 90, 120, 144,
or 240 Hz. Pointer movement is integrated using elapsed time, so changing the
polling rate affects smoothness rather than speed.

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
- Recognized text is inserted only through the focused Accessibility text
  element. Secure Input and secure text fields are refused; the clipboard is
  never used as a fallback.

## Voice limitation

The DualSense microphone button is used as the PTT control. Audio is captured
from the macOS-supported input explicitly selected in Helm. The app does not
claim that the controller's built-in microphone is available as a Mac input.

## Requirements

- macOS 14 or later
- Apple Command Line Tools or Xcode
- A DualSense or DualSense Edge
- SDL3 3.4.12 macOS framework

The current Demo is ad-hoc signed for local development. Real controller,
Accessibility, and speech behavior should be validated on the target Mac before
relying on it for everyday use.

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
ditto /Volumes/SDL3/SDL3.framework macos-app/.vendor/SDL3.framework
hdiutil detach /Volumes/SDL3
```

Then run:

```bash
macos-app/scripts/build-and-install.sh --launch
```

The script runs the deterministic control-math/audio tests, compiles Swift and C
with warnings treated as errors, embeds SDL3, applies an ad-hoc signature, and
installs to `~/Applications/Helm Demo.app`. It temporarily preserves the prior
installation during replacement, verifies the installed copy, and removes the
temporary copy after success.

## Privacy permissions

Helm does not request privacy permissions at launch. Use the visible permission
buttons when you are ready, complete the macOS System Settings flow, return to
Helm, and select **Refresh**.

## License

Helm source code is available under the [MIT License](LICENSE). SDL3 is a
separate dependency distributed under the zlib license and is not committed to
this repository.

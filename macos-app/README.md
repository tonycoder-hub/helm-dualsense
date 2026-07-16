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
   and the microphone button controls PTT.
6. Hold Options, then press the touchpad button within two seconds to use the
   emergency enable/disable gesture.

The control center can remap Cross, Circle, Create, D-pad up/down, and the
microphone button. It also exposes the controller polling rate and a smooth
hold-to-accelerate curve for the left stick. These settings persist locally.

The **Hold to Test** control lets you test microphone selection and speech
recognition without a controller. Text insertion uses the focused
Accessibility element directly; secure fields and system secure-input mode are
refused. It never uses the clipboard as a hidden fallback.

Sony does not support the DualSense built-in microphone as a Mac audio input.
The controller microphone button controls PTT; the visible microphone picker
selects the actual Mac-supported input source.

## Build locally

The checked-out official SDL framework must be present at
`macos-app/.vendor/SDL3.framework`. Then run:

```bash
macos-app/scripts/build-and-install.sh --launch
```

The script runs the pure mapping tests, builds with the installed Command Line
Tools, embeds SDL3, applies an ad-hoc signature, verifies the bundle, preserves
the previous installation only while replacement is in progress, and keeps one
installed copy in `~/Applications`.

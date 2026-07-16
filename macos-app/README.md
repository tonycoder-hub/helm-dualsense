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
`macos-app/.vendor/SDL3.framework`. Then run:

```bash
macos-app/scripts/build-and-install.sh --launch
```

The script runs the pure mapping tests, builds with the installed Command Line
Tools, embeds SDL3, applies an ad-hoc signature, verifies the bundle, preserves
the previous installation only while replacement is in progress, and keeps one
installed copy in `~/Applications`.

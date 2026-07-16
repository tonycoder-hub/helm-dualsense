# Haptic feedback

Helm 0.6 uses SDL's whole-gamepad rumble capability as a conservative first
backend. It does not use trigger rumble: SDL documents trigger rumble as an
Xbox One feature, so treating it as DualSense adaptive-trigger support would be
misleading.

## Interaction policy

- Haptics are off by default and require explicit opt-in.
- The initial master intensity is 35%, adjustable from 20% to 100%.
- Short, finite pulses acknowledge discrete events: enabling controls, click,
  page navigation, keyboard shortcuts, and PTT start/stop.
- Pointer movement, scrolling, trigger speed changes, and stick sampling never
  rumble continuously.
- A 55 ms limiter coalesces accidental bursts. Every pulse is capped at 250 ms
  in the C bridge.
- Disconnect, emergency stop, app shutdown, and disabling haptics all send an
  explicit stop and reset the limiter.
- The UI reports SDL's runtime capability before offering a test pulse. Source
  tests verify envelopes and safety gates, but actual feel remains a USB and
  Bluetooth hardware-tuning task.

The envelopes deliberately use more high-frequency energy for crisp actions
and more low-frequency energy for warnings. They are product semantics rather
than raw motor values, which allows a future backend to preserve the same
meaning with different hardware APIs.

## Future backends

Core Haptics through GameController is a possible experimental backend for
richer patterns and locality. Adaptive-trigger resistance is a separate
feature through `GCDualSenseAdaptiveTrigger`; it should not be hidden behind
the current rumble setting. Both need real-device lifecycle, transport, and
battery testing before becoming defaults.

Primary references:

- [SDL_RumbleGamepad](https://wiki.libsdl.org/SDL3/SDL_RumbleGamepad)
- [SDL_RumbleGamepadTriggers](https://wiki.libsdl.org/SDL3/SDL_RumbleGamepadTriggers)
- [SDL gamepad properties](https://wiki.libsdl.org/SDL3/SDL_GetGamepadProperties)
- [Apple GameController haptics](https://developer.apple.com/documentation/gamecontroller/gccontroller/haptics)
- [GCDeviceHaptics](https://developer.apple.com/documentation/gamecontroller/gcdevicehaptics)
- [GCDualSenseAdaptiveTrigger](https://developer.apple.com/documentation/gamecontroller/gcdualsenseadaptivetrigger)

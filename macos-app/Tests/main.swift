import CoreGraphics
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

expect(
  ControlMath.safetyChordIsValid(modifierPressedAt: 10, buttonPressedAt: 12),
  "two-second chord boundary should be accepted"
)
expect(
  !ControlMath.safetyChordIsValid(modifierPressedAt: 10, buttonPressedAt: 12.001),
  "expired safety chord should be rejected"
)

var remainder = 0.0
expect(
  ControlMath.scrollDelta(
    axis: 0.1,
    deadZone: 0.18,
    gain: 8,
    deltaTime: 1.0 / 60.0,
    remainder: &remainder
  ) == 0,
  "scroll dead zone should suppress motion"
)
expect(
  ControlMath.scrollDelta(
    axis: 1,
    deadZone: 0.18,
    gain: 8,
    deltaTime: 1.0 / 60.0,
    remainder: &remainder
  ) == -8,
  "full downward stick should create deterministic scroll"
)

let pointer = ControlMath.pointerDelta(
  from: CGPoint(x: 0.1, y: 0.1),
  to: CGPoint(x: 0.9, y: 0.9),
  elapsed: 0.016,
  surfaceSize: CGSize(width: 1_920, height: 1_070),
  gain: 1,
  acceleration: 0.35,
  maximum: 180
)
expect(hypot(pointer.x, pointer.y) <= 180.001, "pointer delta should be capped")

let centeredStick = ControlMath.stickPointerDelta(
  x: 0.1,
  y: 0.1,
  deadZone: ControlMath.stickDeadZone,
  gain: 1,
  maximumSpeed: ControlMath.stickPointerMaximumSpeed,
  holdDuration: 0,
  accelerationDuration: 1.6,
  maximumBoost: 2.2,
  deltaTime: 1.0 / 60.0
)
expect(centeredStick == .zero, "radial stick dead zone should suppress drift")

let fullStick = ControlMath.stickPointerDelta(
  x: 1,
  y: 0,
  deadZone: ControlMath.stickDeadZone,
  gain: 1,
  maximumSpeed: 1_200,
  holdDuration: 0,
  accelerationDuration: 1.6,
  maximumBoost: 2.2,
  deltaTime: 1.0 / 60.0
)
expect(abs(fullStick.x - 20) < 0.001, "full stick speed should integrate by elapsed time")
expect(abs(fullStick.y) < 0.001, "horizontal stick motion should not move vertically")

let diagonalStick = ControlMath.stickPointerDelta(
  x: 1,
  y: 1,
  deadZone: ControlMath.stickDeadZone,
  gain: 1,
  maximumSpeed: 1_200,
  holdDuration: 0,
  accelerationDuration: 1.6,
  maximumBoost: 2.2,
  deltaTime: 1.0 / 60.0
)
expect(
  hypot(diagonalStick.x, diagonalStick.y) <= 20.001,
  "diagonal stick speed should be capped radially")

expect(
  ControlMath.stickHoldBoost(
    holdDuration: ControlMath.stickAccelerationDelay,
    delay: ControlMath.stickAccelerationDelay,
    accelerationDuration: 1.6,
    maximumBoost: 2.2
  ) == 1,
  "stick hold acceleration should wait for its delay"
)
let midBoost = ControlMath.stickHoldBoost(
  holdDuration: ControlMath.stickAccelerationDelay + 0.8,
  delay: ControlMath.stickAccelerationDelay,
  accelerationDuration: 1.6,
  maximumBoost: 2.2
)
expect(abs(midBoost - 1.6) < 0.001, "stick hold curve should use smoothstep at midpoint")
expect(
  ControlMath.stickHoldBoost(
    holdDuration: 99,
    delay: ControlMath.stickAccelerationDelay,
    accelerationDuration: 1.6,
    maximumBoost: 2.2
  ) == 2.2,
  "stick hold acceleration should cap at its configured boost"
)

let mappingData = try! JSONEncoder().encode(ControllerMapping.standard)
let decodedMapping = try! JSONDecoder().decode(ControllerMapping.self, from: mappingData)
expect(decodedMapping == .standard, "controller mapping should persist losslessly")
expect(ControlMath.maximumTimerGap == 0.250, "timer-gap contract changed unexpectedly")

func testIsolatedInputAvoidsBluetoothDefault() {
  let bluetooth = AudioInputDevice(
    id: 101,
    name: "Bluetooth headset",
    isDefault: true,
    transport: .bluetooth
  )
  let builtIn = AudioInputDevice(
    id: 102,
    name: "Built-in microphone",
    isDefault: false,
    transport: .builtIn
  )

  let selected = AudioInputCatalog.preferredInput(
    from: [bluetooth, builtIn],
    protectPlayback: true
  )
  expect(selected?.id == builtIn.id, "isolated capture should avoid a Bluetooth default mic")
}

testIsolatedInputAvoidsBluetoothDefault()

func testEnablingPlaybackProtectionStopsActiveBluetoothCapture() {
  let bluetooth = AudioInputDevice(
    id: 201,
    name: "Bluetooth headset",
    isDefault: true,
    transport: .bluetooth
  )
  let builtIn = AudioInputDevice(
    id: 202,
    name: "Built-in microphone",
    isDefault: false,
    transport: .builtIn
  )
  let plan = AudioInputCatalog.playbackProtectionPlan(
    selected: bluetooth,
    from: [bluetooth, builtIn],
    captureActive: true
  )
  expect(plan?.replacement?.id == builtIn.id, "playback protection should select a safe mic")
  expect(
    plan?.shouldStopCapture == true,
    "playback protection must stop an already-running Bluetooth capture"
  )
}

testEnablingPlaybackProtectionStopsActiveBluetoothCapture()

func testTextAreaFallsBackToUnicodeKeyboardEvents() {
  let decision = TextInsertionPolicy.decision(
    secureInputEnabled: false,
    secureField: false,
    focusedRole: "AXTextArea",
    selectedTextSettable: false
  )
  expect(
    decision == .unicodeKeyboardEvents,
    "editable focused text should use a non-clipboard keyboard fallback"
  )
}

testTextAreaFallsBackToUnicodeKeyboardEvents()

func testSecureInputRefusesEveryInsertionPath() {
  let decision = TextInsertionPolicy.decision(
    secureInputEnabled: true,
    secureField: false,
    focusedRole: "AXTextArea",
    selectedTextSettable: true
  )
  expect(decision == .refused, "secure input must block AX and keyboard insertion")
}

testSecureInputRefusesEveryInsertionPath()

func testSecureFieldRefusesEveryInsertionPath() {
  let decision = TextInsertionPolicy.decision(
    secureInputEnabled: false,
    secureField: true,
    focusedRole: "AXTextField",
    selectedTextSettable: true
  )
  expect(decision == .refused, "secure text fields must block AX and keyboard insertion")
}

testSecureFieldRefusesEveryInsertionPath()

func testWritableSelectedTextUsesAccessibilityInsertion() {
  let decision = TextInsertionPolicy.decision(
    secureInputEnabled: false,
    secureField: false,
    focusedRole: "AXTextArea",
    selectedTextSettable: true
  )
  expect(
    decision == .accessibilitySelectedText,
    "writable selected text should keep the direct Accessibility insertion path"
  )
}

testWritableSelectedTextUsesAccessibilityInsertion()

func testUnicodeFallbackIsReportedAsUnconfirmedDispatch() {
  expect(
    TextInsertionPolicy.deliveryConfidence(for: .unicodeKeyboardEvents) == .unconfirmedDispatch,
    "Unicode keyboard events must not be reported as a confirmed insertion"
  )
}

testUnicodeFallbackIsReportedAsUnconfirmedDispatch()

func testShortcutSettingsPersistLosslessly() {
  let settings = ControllerShortcutSettings.standard
  let data = try! JSONEncoder().encode(settings)
  let decoded = try! JSONDecoder().decode(ControllerShortcutSettings.self, from: data)
  expect(decoded == settings, "external input-method shortcut slots should persist losslessly")
}

testShortcutSettingsPersistLosslessly()

func testControllerMappingAcceptsShortcutActions() {
  var mapping = ControllerMapping.standard
  mapping.create = .shortcut1
  let data = try! JSONEncoder().encode(mapping)
  let decoded = try! JSONDecoder().decode(ControllerMapping.self, from: data)
  expect(decoded == mapping, "controller buttons should persist external shortcut actions")
}

testControllerMappingAcceptsShortcutActions()

func testFullL2BrakeUsesConfiguredMinimumSpeed() {
  let multiplier = ControlMath.racingSpeedMultiplier(
    brake: 1,
    accelerator: 0,
    minimumSpeed: 0.25,
    maximumSpeed: 3
  )
  expect(abs(multiplier - 0.25) < 0.001, "full L2 should brake to the configured minimum")
}

testFullL2BrakeUsesConfiguredMinimumSpeed()

func testFullR2AcceleratorUsesConfiguredMaximumSpeed() {
  let multiplier = ControlMath.racingSpeedMultiplier(
    brake: 0,
    accelerator: 1,
    minimumSpeed: 0.25,
    maximumSpeed: 3
  )
  expect(abs(multiplier - 3) < 0.001, "full R2 should accelerate to the configured maximum")
}

testFullR2AcceleratorUsesConfiguredMaximumSpeed()

func testShortcutKeysResolveToMacVirtualKeyCodes() {
  expect(ShortcutKey.d.virtualKeyCode == 2, "shortcut D should use the macOS ANSI D key code")
  expect(ShortcutKey.space.virtualKeyCode == 49, "shortcut Space should use key code 49")
}

testShortcutKeysResolveToMacVirtualKeyCodes()

func testShortcutKeysExposeReadableTitles() {
  expect(ShortcutKey.returnKey.title == "Return", "shortcut picker should name the Return key")
}

testShortcutKeysExposeReadableTitles()

func testShortcutDefinitionBuildsMacStyleLabel() {
  expect(
    ControllerShortcutSettings.standard.slot1.label == "⌃⌥D",
    "shortcut labels should expose their modifiers and key"
  )
}

testShortcutDefinitionBuildsMacStyleLabel()

func testHelmActivationPreservesLastExternalFocusOwner() {
  var history = ExternalFocusHistory()
  history.recordActivation(processIdentifier: 42, helmProcessIdentifier: 10)
  history.recordActivation(processIdentifier: 10, helmProcessIdentifier: 10)
  expect(
    history.restorationTarget(
      currentProcessIdentifier: 10,
      helmProcessIdentifier: 10
    ) == 42,
    "on-screen PTT should be able to restore the last external focus owner"
  )
}

testHelmActivationPreservesLastExternalFocusOwner()

func testEmptyFocusHistoryFallsBackToWindowOrder() {
  let history = ExternalFocusHistory()
  let targets = history.restorationTargets(
    currentProcessIdentifier: 10,
    helmProcessIdentifier: 10,
    fallbackProcessIdentifiers: [10, 77, 77, 0, 88]
  )
  expect(
    targets == [77, 88],
    "first-run on-screen PTT should fall back to external front-to-back window owners"
  )
}

testEmptyFocusHistoryFallsBackToWindowOrder()

func testCancelledVoiceTestGenerationCannotAffectNextSession() {
  var generation = VoiceTestSessionGeneration()
  let cancelled = generation.begin()
  generation.invalidate()
  let replacement = generation.begin()
  expect(
    !generation.accepts(cancelled),
    "a cancelled UI PTT callback must not affect the next voice session"
  )
  expect(generation.accepts(replacement), "the replacement UI PTT token should remain current")
}

testCancelledVoiceTestGenerationCannotAffectNextSession()

func testCombinedAccelerationHasAnAbsolutePointerSpeedCap() {
  let delta = ControlMath.stickPointerDelta(
    x: 1,
    y: 0,
    deadZone: ControlMath.stickDeadZone,
    gain: 2.2 * 4,
    maximumSpeed: ControlMath.stickPointerMaximumSpeed,
    holdDuration: 99,
    accelerationDuration: 0.4,
    maximumBoost: 3,
    deltaTime: 1.0 / 60.0
  )
  expect(
    hypot(delta.x, delta.y) <= ControlMath.stickPointerAbsoluteMaximumSpeed / 60 + 0.001,
    "pointer gain, hold boost, and R2 acceleration must share a final speed cap"
  )
}

testCombinedAccelerationHasAnAbsolutePointerSpeedCap()

func testPrimaryActionHapticIsCrispAndShort() {
  let pulse = HapticFeedbackPolicy.pulse(for: .primaryAction, intensity: 1)
  expect(
    pulse.highFrequency > pulse.lowFrequency,
    "primary-action feedback should emphasize the crisp high-frequency actuator"
  )
  expect(pulse.durationMilliseconds <= 30, "primary-action feedback should stay short")
}

testPrimaryActionHapticIsCrispAndShort()

func testWarningHapticFeelsHeavierThanAnAction() {
  let pulse = HapticFeedbackPolicy.pulse(for: .warning, intensity: 1)
  expect(
    pulse.lowFrequency > pulse.highFrequency,
    "warning feedback should emphasize the low-frequency actuator"
  )
  expect(pulse.durationMilliseconds <= 90, "warning feedback should remain bounded")
}

testWarningHapticFeelsHeavierThanAnAction()

func testHapticIntensityIsClamped() {
  let maximum = HapticFeedbackPolicy.pulse(for: .preview, intensity: 1)
  expect(
    HapticFeedbackPolicy.pulse(for: .preview, intensity: 2) == maximum,
    "haptic intensity above one should clamp to the tuned maximum"
  )
  let muted = HapticFeedbackPolicy.pulse(for: .preview, intensity: -1)
  expect(
    muted.lowFrequency == 0 && muted.highFrequency == 0,
    "negative haptic intensity should clamp to silence"
  )
}

testHapticIntensityIsClamped()

func testHapticRateLimiterPreventsBuzzing() {
  var limiter = HapticRateLimiter(minimumInterval: 0.055)
  expect(limiter.accepts(now: 10), "the first semantic haptic should be accepted")
  expect(!limiter.accepts(now: 10.03), "closely repeated haptics should be coalesced")
  expect(limiter.accepts(now: 10.055), "a haptic at the interval boundary should be accepted")
  limiter.reset()
  expect(limiter.accepts(now: 10.056), "safety reset should clear the haptic limiter")
}

testHapticRateLimiterPreventsBuzzing()

func testHapticGateNeverRumblesAtStartup() {
  expect(
    !HapticFeedbackPolicy.shouldPlay(
      enabled: true,
      intensity: 0.65,
      available: true,
      connected: true,
      controlsEnabled: false,
      allowsDisabledControls: false
    ),
    "semantic haptics should remain silent until controls are explicitly enabled"
  )
  expect(
    HapticFeedbackPolicy.shouldPlay(
      enabled: true,
      intensity: 0.65,
      available: true,
      connected: true,
      controlsEnabled: false,
      allowsDisabledControls: true
    ),
    "the explicit preview action may vibrate while controls are disabled"
  )
}

testHapticGateNeverRumblesAtStartup()

func testHapticDefaultsRequireExplicitOptIn() {
  expect(!HapticFeedbackPolicy.defaultEnabled, "haptics should default to explicit opt-in")
  expect(
    abs(HapticFeedbackPolicy.defaultIntensity - 0.35) < 0.001,
    "the initial haptic intensity should stay conservative"
  )
}

testHapticDefaultsRequireExplicitOptIn()

final class RecordingHapticBackend: HapticBackend {
  var available = true
  var succeeds = false
  var played: [HapticPulse] = []
  var stopCount = 0

  func isAvailable() -> Bool { available }

  func play(_ pulse: HapticPulse) -> Bool {
    played.append(pulse)
    return succeeds
  }

  func stop() {
    stopCount += 1
  }
}

func testFailedHapticDoesNotPoisonTheNextAttempt() {
  let backend = RecordingHapticBackend()
  var coordinator = HapticCoordinator(minimumInterval: 0.055)
  expect(
    !coordinator.play(
      .preview,
      intensity: 0.35,
      enabled: true,
      connected: true,
      controlsEnabled: false,
      allowsDisabledControls: true,
      now: 10,
      backend: backend
    ),
    "a backend failure should be reported"
  )
  backend.succeeds = true
  expect(
    coordinator.play(
      .preview,
      intensity: 0.35,
      enabled: true,
      connected: true,
      controlsEnabled: false,
      allowsDisabledControls: true,
      now: 10.001,
      backend: backend
    ),
    "a failed output must release the limiter for the next attempt"
  )
  coordinator.stop(backend: backend)
  expect(backend.stopCount == 1, "coordinator stop should release the active backend")
}

testFailedHapticDoesNotPoisonTheNextAttempt()

let audioInputs = AudioInputCatalog.devices()
expect(!audioInputs.isEmpty, "at least one Mac-supported audio input should be discoverable")
expect(audioInputs.contains(where: { $0.isDefault }), "default audio input should be identified")

print("CONTROL_MATH_AND_AUDIO_TESTS=PASS inputs=\(audioInputs.count)")

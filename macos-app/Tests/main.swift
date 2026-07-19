import AppKit
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

func testInputAndMotionOutputCadenceAreLockedTo240Hz() {
  expect(
    InputCadencePolicy.clampedRate(60) == 240
      && InputCadencePolicy.clampedRate(1_000) == 240,
    "every requested input rate must resolve to the fixed 240 Hz cadence"
  )
  expect(
    InputCadencePolicy.selectableRates == [240],
    "the UI must not advertise lower cadence options after lock mode is enabled"
  )
  expect(
    MotionOutputCadencePolicy.mode == .fixed240,
    "global pointer and scroll delivery must bypass background-throttled display links"
  )
  expect(
    MotionOutputCadencePolicy.deliveryRoute == .immediate,
    "fixed 240 Hz motion must flush on the sampling tick without a display-link dependency"
  )
}

testInputAndMotionOutputCadenceAreLockedTo240Hz()

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
    selectedTextSettable: false,
    selectedTextStateReadable: false
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
    selectedTextSettable: true,
    selectedTextStateReadable: true
  )
  expect(decision == .refused, "secure input must block AX and keyboard insertion")
}

testSecureInputRefusesEveryInsertionPath()

func testSecureFieldRefusesEveryInsertionPath() {
  let decision = TextInsertionPolicy.decision(
    secureInputEnabled: false,
    secureField: true,
    focusedRole: "AXTextField",
    selectedTextSettable: true,
    selectedTextStateReadable: true
  )
  expect(decision == .refused, "secure text fields must block AX and keyboard insertion")
}

testSecureFieldRefusesEveryInsertionPath()

func testWritableSelectedTextUsesAccessibilityInsertion() {
  let decision = TextInsertionPolicy.decision(
    secureInputEnabled: false,
    secureField: false,
    focusedRole: "AXTextArea",
    selectedTextSettable: true,
    selectedTextStateReadable: true
  )
  expect(
    decision == .accessibilitySelectedText,
    "writable selected text should keep the direct Accessibility insertion path"
  )
}

testWritableSelectedTextUsesAccessibilityInsertion()

func testUnreadableWebEditorSkipsUnverifiableAccessibilityWrite() {
  let decision = TextInsertionPolicy.decision(
    secureInputEnabled: false,
    secureField: false,
    focusedRole: "AXTextArea",
    selectedTextSettable: true,
    selectedTextStateReadable: false,
    confirmedExternalTarget: true
  )
  expect(
    decision == .unicodeKeyboardEvents,
    "an unreadable web editor must use keyboard delivery instead of stopping after an unverifiable AX write"
  )
}

testUnreadableWebEditorSkipsUnverifiableAccessibilityWrite()

func testUnicodeFallbackIsReportedAsUnconfirmedDispatch() {
  expect(
    TextInsertionPolicy.deliveryConfidence(for: .unicodeKeyboardEvents) == .unconfirmedDispatch,
    "Unicode keyboard events must not be reported as a confirmed insertion"
  )
}

testUnicodeFallbackIsReportedAsUnconfirmedDispatch()

func testConfirmedExternalWebEditorUsesUnicodeDelivery() {
  let decision = TextInsertionPolicy.decision(
    secureInputEnabled: false,
    secureField: false,
    focusedRole: "AXGroup",
    selectedTextSettable: false,
    selectedTextStateReadable: false,
    confirmedExternalTarget: true
  )
  expect(
    decision == .unicodeKeyboardEvents,
    "a confirmed external web editor should accept Unicode delivery even when AX exposes a group"
  )
}

testConfirmedExternalWebEditorUsesUnicodeDelivery()

func testPointerEventCarriesHardwareMotionMetadata() {
  let origin = CGPoint(x: 100, y: 100)
  guard let event = PointerEventFactory.make(
    origin: origin,
    delta: CGPoint(x: 0.25, y: -0.25),
    displayBounds: [CGRect(x: 0, y: 0, width: 1_000, height: 1_000)],
    mouseType: .mouseMoved,
    mouseButton: .left
  ) else {
    expect(false, "the HID pointer event should be constructible")
    return
  }
  expect(
    event.getIntegerValueField(.eventSourceStateID)
      == Int64(CGEventSourceStateID.hidSystemState.rawValue),
    "gamepad pointer events must use the HID system state"
  )
  expect(
    event.getIntegerValueField(.mouseEventDeltaX) == 1
      && event.getIntegerValueField(.mouseEventDeltaY) == -1,
    "fractional absolute movement must still advertise nonzero hardware delta velocity"
  )
  expect(
    event.flags.contains(.maskNonCoalesced),
    "each display-frame pointer event must remain non-coalesced"
  )
  expect(
    abs(event.location.x - 100.25) < 0.000_001
      && abs(event.location.y - 99.75) < 0.000_001,
    "hardware metadata must not quantize the precise absolute target"
  )
}

testPointerEventCarriesHardwareMotionMetadata()

func testPointerButtonsShareTheHardwareEventState() {
  guard let event = PointerEventFactory.makeButtonEvent(
    location: CGPoint(x: 100, y: 100),
    button: .left,
    pressed: true
  ) else {
    expect(false, "the HID pointer button event should be constructible")
    return
  }
  expect(
    event.type == .leftMouseDown
      && event.getIntegerValueField(.eventSourceStateID)
        == Int64(CGEventSourceStateID.hidSystemState.rawValue),
    "pointer movement and button state must share the HID system state"
  )
}

testPointerButtonsShareTheHardwareEventState()

func testUnicodeKeyboardEventsUseHardwareEventState() {
  guard let pair = UnicodeKeyboardEventFactory.make(chunk: "你") else {
    expect(false, "Unicode HID events should be constructible")
    return
  }
  let expectedState = Int64(CGEventSourceStateID.hidSystemState.rawValue)
  expect(
    pair.keyDown.getIntegerValueField(.eventSourceStateID) == expectedState
      && pair.keyUp.getIntegerValueField(.eventSourceStateID) == expectedState,
    "controller-originated Unicode text must use the HID system event state"
  )
  expect(
    pair.keyDown.type == .keyDown && pair.keyUp.type == .keyUp,
    "Unicode delivery must preserve one complete down/up pair"
  )
  expect(
    pair.keyDown.flags.isEmpty && pair.keyUp.flags.isEmpty,
    "recognized text events must not inherit a held Command, Option, Control, or Shift key"
  )
}

testUnicodeKeyboardEventsUseHardwareEventState()

func testFocusedElementResolutionPrefersTheSystemWideEditor() {
  expect(
    TextInsertionPolicy.focusedElementSource(
      expectedProcessIdentifier: 42,
      systemWideProcessIdentifier: 42,
      applicationProcessIdentifier: 42,
      allowsApplicationFallback: false
    ) == .systemWide,
    "the system-wide focused element is the authoritative live editor"
  )
  expect(
    TextInsertionPolicy.focusedElementSource(
      expectedProcessIdentifier: 42,
      systemWideProcessIdentifier: 10,
      applicationProcessIdentifier: 42,
      allowsApplicationFallback: false
    ) == .unavailable,
    "live global delivery must reject an application-level stale editor"
  )
  expect(
    TextInsertionPolicy.focusedElementSource(
      expectedProcessIdentifier: 42,
      systemWideProcessIdentifier: 10,
      applicationProcessIdentifier: 42,
      allowsApplicationFallback: true
    ) == .application,
    "an inactive target may fall back to its application-level focused element for restoration"
  )
  expect(
    TextInsertionPolicy.focusedElementSource(
      expectedProcessIdentifier: 42,
      systemWideProcessIdentifier: 10,
      applicationProcessIdentifier: 11,
      allowsApplicationFallback: true
    ) == .unavailable,
    "focus resolution must reject elements owned by another process"
  )
}

testFocusedElementResolutionPrefersTheSystemWideEditor()

func testConfirmedInsertionClearsTheManualRetryPayload() {
  expect(
    TextInsertionPolicy.retryText(
      after: .confirmedInsertion,
      originalText: "已经写入"
    ) == nil,
    "a read-back-confirmed insertion must not remain available for duplicate delivery"
  )
  expect(
    TextInsertionPolicy.retryText(
      after: .unconfirmedDispatch,
      originalText: "需要确认"
    ) == "需要确认",
    "an unconfirmed dispatch should remain manually recoverable"
  )
}

testConfirmedInsertionClearsTheManualRetryPayload()

func testPointerDesktopGeometryRejectsDisplayLayoutHoles() {
  let displays = [
    CGRect(x: 0, y: 0, width: 100, height: 100),
    CGRect(x: 100, y: 0, width: 100, height: 50),
  ]
  let projected = PointerDesktopGeometry.projectedTarget(
    origin: CGPoint(x: 90, y: 90),
    delta: CGPoint(x: 30, y: 0),
    displayBounds: displays
  )
  expect(
    projected == CGPoint(x: 99, y: 90),
    "a target inside an L-shaped desktop hole must project to the nearest real display edge"
  )
  expect(
    PointerDesktopGeometry.projectedTarget(
      origin: CGPoint(x: 90, y: 20),
      delta: CGPoint(x: 30, y: 0),
      displayBounds: displays
    ) == CGPoint(x: 120, y: 20),
    "a valid cross-display target must retain its precise coordinates"
  )
}

testPointerDesktopGeometryRejectsDisplayLayoutHoles()

func testExternalFocusMustBelongToTheCapturedApplication() {
  expect(
    TextInsertionPolicy.externalFocusReadiness(
      expectedProcessIdentifier: 42,
      helmProcessIdentifier: 10,
      frontmostProcessIdentifier: 42,
      focusedElementProcessIdentifier: 10
    ) == .retry,
    "a stale Helm AX focus must not be accepted for an external insertion target"
  )
  expect(
    TextInsertionPolicy.externalFocusReadiness(
      expectedProcessIdentifier: 42,
      helmProcessIdentifier: 10,
      frontmostProcessIdentifier: 42,
      focusedElementProcessIdentifier: nil
    ) == .retry,
    "an external app whose AX focus is not ready yet should be retried"
  )
  expect(
    TextInsertionPolicy.externalFocusReadiness(
      expectedProcessIdentifier: 42,
      helmProcessIdentifier: 10,
      frontmostProcessIdentifier: 42,
      focusedElementProcessIdentifier: 42
    ) == .ready,
    "only a focused AX element owned by the captured app is ready for insertion"
  )
}

testExternalFocusMustBelongToTheCapturedApplication()

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

func testModifierOnlyShortcutDoesNotRequireAPrimaryKey() {
  let commandOnly = KeyboardShortcutDefinition(
    key: nil,
    command: true,
    option: false,
    control: false,
    shift: false
  )
  expect(commandOnly.isModifierOnly, "Command-only should be a valid modifier-only shortcut")
  expect(commandOnly.label == "⌘", "Command-only should have a readable macOS label")
  expect(
    commandOnly.modifierVirtualKeyCodes == [55],
    "Command-only should use the left Command virtual key"
  )
}

testModifierOnlyShortcutDoesNotRequireAPrimaryKey()

func testModifierOnlyShortcutPersistsLosslessly() {
  let commandOnly = KeyboardShortcutDefinition(
    key: nil,
    command: true,
    option: false,
    control: false,
    shift: false
  )
  let data = try! JSONEncoder().encode(commandOnly)
  let decoded = try! JSONDecoder().decode(KeyboardShortcutDefinition.self, from: data)
  expect(decoded == commandOnly, "a modifier-only shortcut should survive persistence")
}

testModifierOnlyShortcutPersistsLosslessly()

func testRightCommandModifierIsRepresentedPhysically() {
  let rightCommandOnly = KeyboardShortcutDefinition(
    key: nil,
    commandSide: .right,
    optionSide: .none,
    controlSide: .none,
    shiftSide: .none
  )
  expect(rightCommandOnly.isModifierOnly, "right Command alone should be a valid held shortcut")
  expect(rightCommandOnly.label == "右⌘", "right Command should be distinguishable in the UI")
  expect(
    rightCommandOnly.modifierVirtualKeyCodes == [54],
    "right Command should use the macOS right-Command virtual key code"
  )
}

testRightCommandModifierIsRepresentedPhysically()

func testLegacyBooleanModifiersMigrateToLeftPhysicalKeys() {
  let legacy = Data(
    #"{"key":null,"command":true,"option":false,"control":true,"shift":false}"#.utf8
  )
  let decoded = try! JSONDecoder().decode(KeyboardShortcutDefinition.self, from: legacy)
  expect(
    decoded.commandSide == .left && decoded.controlSide == .left,
    "existing shortcut settings should migrate to the historically emitted left modifiers"
  )
  expect(
    decoded.modifierVirtualKeyCodes == [59, 55],
    "legacy Control+Command should retain its physical key codes after migration"
  )
}

testLegacyBooleanModifiersMigrateToLeftPhysicalKeys()

func testRightCommandShortcutEmitsPhysicalModifierTransitions() {
  let shortcut = KeyboardShortcutDefinition(
    key: .d,
    commandSide: .right,
    optionSide: .none,
    controlSide: .none,
    shiftSide: .none
  )
  expect(
    KeyboardShortcutEventPlanner.plan(for: shortcut) == [
      KeyboardEventStep(
        virtualKeyCode: 54,
        pressed: true,
        activeModifierVirtualKeyCodes: [54]
      ),
      KeyboardEventStep(
        virtualKeyCode: 2,
        pressed: true,
        activeModifierVirtualKeyCodes: [54]
      ),
      KeyboardEventStep(
        virtualKeyCode: 2,
        pressed: false,
        activeModifierVirtualKeyCodes: [54]
      ),
      KeyboardEventStep(
        virtualKeyCode: 54,
        pressed: false,
        activeModifierVirtualKeyCodes: []
      ),
    ],
    "right Command combinations should emit the physical right modifier around the primary key"
  )
}

testRightCommandShortcutEmitsPhysicalModifierTransitions()

func testModifierHoldCoordinatorPreservesOtherSlotsFlags() {
  var coordinator = ModifierHoldCoordinator()
  expect(
    coordinator.update(slot: 1, source: 10, modifierCodes: [55], pressed: true)
      == [
        ModifierKeyTransition(
          virtualKeyCode: 55,
          pressed: true,
          activeModifierVirtualKeyCodes: [55]
        )
      ],
    "the first Command owner should press the physical modifier"
  )
  expect(
    coordinator.update(slot: 2, source: 11, modifierCodes: [59], pressed: true)
      == [
        ModifierKeyTransition(
          virtualKeyCode: 59,
          pressed: true,
          activeModifierVirtualKeyCodes: [59, 55]
        )
      ],
    "pressing Control in another slot must preserve Command in the event flags"
  )
  expect(
    coordinator.update(slot: 1, source: 10, modifierCodes: [55], pressed: false)
      == [
        ModifierKeyTransition(
          virtualKeyCode: 55,
          pressed: false,
          activeModifierVirtualKeyCodes: [59]
        )
      ],
    "releasing Command must leave another slot's Control flag active"
  )
}

testModifierHoldCoordinatorPreservesOtherSlotsFlags()

func testModifierHoldCoordinatorReferenceCountsOverlappingSlots() {
  var coordinator = ModifierHoldCoordinator()
  _ = coordinator.update(slot: 1, source: 20, modifierCodes: [55], pressed: true)
  expect(
    coordinator.update(slot: 2, source: 21, modifierCodes: [55], pressed: true).isEmpty,
    "a second Command owner must not repeat physical key-down"
  )
  expect(
    coordinator.update(slot: 1, source: 20, modifierCodes: [55], pressed: false).isEmpty,
    "releasing one slot must not release Command while another slot owns it"
  )
  expect(
    coordinator.update(slot: 2, source: 21, modifierCodes: [55], pressed: false)
      == [
        ModifierKeyTransition(
          virtualKeyCode: 55,
          pressed: false,
          activeModifierVirtualKeyCodes: []
        )
      ],
    "the final Command owner should release the physical modifier"
  )
}

testModifierHoldCoordinatorReferenceCountsOverlappingSlots()

func testModifierHoldCoordinatorResetReleasesEveryPhysicalModifier() {
  var coordinator = ModifierHoldCoordinator()
  _ = coordinator.update(slot: 1, source: 30, modifierCodes: [59, 55], pressed: true)
  expect(
    coordinator.reset()
      == [
        ModifierKeyTransition(
          virtualKeyCode: 55,
          pressed: false,
          activeModifierVirtualKeyCodes: [59]
        ),
        ModifierKeyTransition(
          virtualKeyCode: 59,
          pressed: false,
          activeModifierVirtualKeyCodes: []
        ),
      ],
    "emergency cleanup should release all physical modifiers in reverse order"
  )
  expect(coordinator.reset().isEmpty, "a second modifier cleanup should be a no-op")
}

testModifierHoldCoordinatorResetReleasesEveryPhysicalModifier()

func testVoiceStartupSizedTimerGapDoesNotEmergencyStop() {
  expect(
    !TimerGapPolicy.shouldEmergencyStop(elapsed: 0.6, hasActiveInput: true),
    "normal synchronous voice startup must not be mistaken for system sleep"
  )
}

testVoiceStartupSizedTimerGapDoesNotEmergencyStop()

func testActualSleepSizedTimerGapStillEmergencyStops() {
  expect(
    TimerGapPolicy.shouldEmergencyStop(elapsed: 2.1, hasActiveInput: true),
    "a multi-second cadence gap must retain the safety stop"
  )
}

testActualSleepSizedTimerGapStillEmergencyStops()

func testLongFrameDoesNotIntegrateAStaleStickDelta() {
  expect(
    TimerGapPolicy.integrationDeltaTime(elapsed: 0.6) == 0,
    "a long frame should resume without a cursor jump"
  )
  expect(
    TimerGapPolicy.integrationDeltaTime(elapsed: 1.0 / 120.0) == 1.0 / 120.0,
    "a normal display frame should retain its elapsed time"
  )
}

testLongFrameDoesNotIntegrateAStaleStickDelta()

func testConfigurableActiveInputCadenceDefaultsToHighRate() {
  expect(
    InputCadencePolicy.defaultRate == 240,
    "active analog sampling should default to the requested high rate"
  )
  expect(
    InputCadencePolicy.clampedRate(500) == 240
      && InputCadencePolicy.clampedRate(30) == 240,
    "input cadence must stay locked to 240 Hz regardless of stale preferences"
  )
  expect(
    InputCadencePolicy.interval(for: 240) == 1.0 / 240.0,
    "the 240 Hz option should schedule a true 240 Hz active sample interval"
  )
}

testConfigurableActiveInputCadenceDefaultsToHighRate()

func testPolledAnalogSampleReplacesStaleEventState() {
  var state = ControllerAnalogState(
    leftX: 0.1,
    leftY: 0.2,
    rightY: 0.3,
    leftTrigger: 0.4,
    rightTrigger: 0.5
  )
  state.applyPolledSample(
    ControllerAnalogSample(
      leftX: 0.75,
      leftY: -0.6,
      rightY: 0.9,
      leftTrigger: 0.2,
      rightTrigger: 1
    )
  )
  expect(
    state.leftX == 0.75 && state.leftY == -0.6,
    "display-cadence polling should replace sparse left-stick events"
  )
  expect(state.rightY == 0.9, "the same sample should update right-stick scrolling")
  expect(
    state.leftTrigger == 0.2 && state.rightTrigger == 1,
    "the same sample should update both racing triggers"
  )
}

testPolledAnalogSampleReplacesStaleEventState()

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

func testPhysicalPTTCapturesTheCurrentExternalFocusOwner() {
  var history = ExternalFocusHistory()
  history.recordActivation(processIdentifier: 42, helmProcessIdentifier: 10)
  expect(
    history.insertionTarget(
      currentProcessIdentifier: 77,
      helmProcessIdentifier: 10
    ) == 77,
    "physical PTT should target the external app focused when dictation begins"
  )
}

testPhysicalPTTCapturesTheCurrentExternalFocusOwner()

func testLaunchAutoEnableIsDefaultOnAndConsumedOnlyOnce() {
  expect(
    LaunchControlAutoEnablePolicy.defaultEnabled,
    "launch auto-enable should default on for an already connected controller"
  )
  var gate = LaunchControlAutoEnableGate(
    settingEnabled: LaunchControlAutoEnablePolicy.defaultEnabled,
    controllerAlreadyConnected: true
  )
  expect(
    gate.consumeForConnection(),
    "the initial SDL connection event should auto-enable an already connected controller"
  )
  expect(
    !gate.consumeForConnection(),
    "later reconnects must not undo an explicit manual stop in the same app session"
  )

  var lateConnection = LaunchControlAutoEnableGate(
    settingEnabled: true,
    controllerAlreadyConnected: false
  )
  expect(
    !lateConnection.consumeForConnection(),
    "connecting a controller after launch should remain an explicit user action"
  )

  var disabled = LaunchControlAutoEnableGate(
    settingEnabled: false,
    controllerAlreadyConnected: true
  )
  expect(
    !disabled.consumeForConnection(),
    "the persisted setting must disable launch auto-enable"
  )
}

testLaunchAutoEnableIsDefaultOnAndConsumedOnlyOnce()

func testManualRetryRequiresAFreshExternalActivationAfterRecognition() {
  var history = ExternalFocusHistory()
  history.recordActivation(
    processIdentifier: 42,
    processLaunchTime: 100,
    helmProcessIdentifier: 10
  )
  let recognitionCompletedAt = history.activationGeneration
  expect(
    history.manualRetryTarget(after: recognitionCompletedAt) == nil,
    "a pre-existing external PID must not be reused for a later manual retry"
  )
  history.recordActivation(
    processIdentifier: 10,
    processLaunchTime: 200,
    helmProcessIdentifier: 10
  )
  expect(
    history.manualRetryTarget(after: recognitionCompletedAt) == nil,
    "returning to Helm must not count as a fresh external target"
  )
  history.recordActivation(
    processIdentifier: 42,
    processLaunchTime: 100,
    helmProcessIdentifier: 10
  )
  expect(
    history.manualRetryTarget(after: recognitionCompletedAt)
      == ExternalProcessIdentity(processIdentifier: 42, launchTime: 100),
    "an external app activated after recognition should become the retry target"
  )
}

testManualRetryRequiresAFreshExternalActivationAfterRecognition()

func testManualRetryRejectsAReusedProcessIdentifier() {
  let captured = ExternalProcessIdentity(processIdentifier: 42, launchTime: 100)
  expect(
    ExternalProcessIdentityPolicy.matches(
      expected: captured,
      candidateProcessIdentifier: 42,
      candidateLaunchTime: 100
    ),
    "the original process instance should remain valid"
  )
  expect(
    !ExternalProcessIdentityPolicy.matches(
      expected: captured,
      candidateProcessIdentifier: 42,
      candidateLaunchTime: 200
    ),
    "the same PID with a different launch time must be treated as PID reuse"
  )
}

testManualRetryRejectsAReusedProcessIdentifier()

func testVoiceDeliveryKeepsThePTTStartTargetWhenTheFrontmostAppChanges() {
  expect(
    VoiceInsertionTargetPolicy.deliveryTarget(
      capturedProcessIdentifier: 42,
      currentProcessIdentifier: 77,
      helmProcessIdentifier: 10
    ) == 42,
    "recognition completion must not retarget speech to a newly frontmost application"
  )
  expect(
    VoiceInsertionTargetPolicy.deliveryTarget(
      capturedProcessIdentifier: nil,
      currentProcessIdentifier: 77,
      helmProcessIdentifier: 10
    ) == nil,
    "a session without a captured target must not hijack whichever app is frontmost later"
  )
}

testVoiceDeliveryKeepsThePTTStartTargetWhenTheFrontmostAppChanges()

func testVoiceDeliveryRecapturesOnlyAMissingFocusFromTheVerifiedFrontmostTarget() {
  expect(
    TextInsertionPolicy.voiceFocusSnapshotResolution(
      hasCapturedSnapshot: false,
      targetIsFrontmost: true,
      processIdentityMatches: true
    ) == .recaptureCurrentExternalFocus,
    "a verified frontmost target should repair a focus snapshot that was unavailable at PTT start"
  )
  expect(
    TextInsertionPolicy.voiceFocusSnapshotResolution(
      hasCapturedSnapshot: true,
      targetIsFrontmost: true,
      processIdentityMatches: true
    ) == .useCapturedFocus,
    "an existing PTT-start focus snapshot must remain pinned to its original editor"
  )
  expect(
    TextInsertionPolicy.voiceFocusSnapshotResolution(
      hasCapturedSnapshot: false,
      targetIsFrontmost: false,
      processIdentityMatches: true
    ) == .retryAfterActivation,
    "focus must not be recaptured while another application is frontmost"
  )
  expect(
    TextInsertionPolicy.voiceFocusSnapshotResolution(
      hasCapturedSnapshot: false,
      targetIsFrontmost: true,
      processIdentityMatches: false
    ) == .refuse,
    "a reused or replaced target process must never receive recognized text"
  )
}

testVoiceDeliveryRecapturesOnlyAMissingFocusFromTheVerifiedFrontmostTarget()

func testRetryableVoiceDeliveryStopsAfterTheAttemptBudgetIsExhausted() {
  expect(
    VoiceTextDeliveryRetryPolicy.nextAttemptCount(from: 12) == 11,
    "a delayed AX focus should consume one bounded retry"
  )
  expect(
    VoiceTextDeliveryRetryPolicy.nextAttemptCount(from: 0) == nil,
    "exhausted AX focus retries must fail closed instead of looping forever"
  )
}

testRetryableVoiceDeliveryStopsAfterTheAttemptBudgetIsExhausted()

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

func testStickFilterIsTimeInvariantAcrossJitteredFrames() {
  func finalVector(for intervals: [TimeInterval]) -> CGPoint {
    var filter = StickMotionFilter()
    var value = CGPoint.zero
    for interval in intervals {
      value = filter.update(
        x: 0.62,
        y: -0.24,
        deadZone: 0.16,
        responseExponent: 1.35,
        responseTime: 0.024,
        deltaTime: interval
      )
    }
    return value
  }

  let uniform = finalVector(for: Array(repeating: 1.0 / 120.0, count: 120))
  let jittered = finalVector(
    for: Array(repeating: [1.0 / 240.0, 1.0 / 80.0], count: 60).flatMap { $0 })
  expect(
    hypot(uniform.x - jittered.x, uniform.y - jittered.y) < 0.000_001,
    "stick smoothing should depend on elapsed time, not callback regularity"
  )
}

testStickFilterIsTimeInvariantAcrossJitteredFrames()

func testStickFilterStopsImmediatelyInsideTheDeadZone() {
  var filter = StickMotionFilter()
  _ = filter.update(
    x: 0.8,
    y: 0,
    deadZone: 0.16,
    responseExponent: 1.35,
    responseTime: 0.024,
    deltaTime: 1.0 / 120.0
  )
  let stopped = filter.update(
    x: 0.05,
    y: 0.04,
    deadZone: 0.16,
    responseExponent: 1.35,
    responseTime: 0.024,
    deltaTime: 1.0 / 120.0
  )
  expect(stopped == .zero, "returning to the dead zone must not leave cursor glide")
}

testStickFilterStopsImmediatelyInsideTheDeadZone()

func testMappingCaptureSuspendsInjectionWithoutDisablingTheControlSession() {
  let plan = MappingCapturePolicy.begin(
    controlsEnabled: true,
    voiceActive: true,
    injectedInputActive: true
  )
  expect(
    plan.controlsEnabledAfterTransition,
    "starting button capture must preserve the user's enabled control session"
  )
  expect(plan.shouldStopVoice, "button capture should safely stop an active voice session")
  expect(
    plan.shouldReleaseInjectedInputs,
    "button capture should release active mouse and modifier outputs before recording"
  )
}

testMappingCaptureSuspendsInjectionWithoutDisablingTheControlSession()

func testControllerChordRecordingWaitsForEveryButtonRelease() {
  var recorder = ControllerChordRecorder()
  recorder.begin()
  expect(
    recorder.process(button: .leftShoulder, pressed: true) == nil,
    "the first held button should not finish a chord"
  )
  expect(
    recorder.process(button: .south, pressed: true) == nil,
    "a second held button should remain part of the recording"
  )
  expect(
    recorder.process(button: .south, pressed: false) == nil,
    "recording should wait for the final held button"
  )
  let chord = recorder.process(button: .leftShoulder, pressed: false)
  expect(
    chord == ControllerChord(buttons: [.south, .leftShoulder]),
    "the completed recording should contain the canonical two-button chord"
  )
}

testControllerChordRecordingWaitsForEveryButtonRelease()

func testComboMappingPersistsAndReplacesAmbiguousPrefixes() {
  var mapping = ControllerMapping.standard
  let combo = ControllerChord(buttons: [.leftShoulder, .south])!
  let removed = mapping.upsert(ControllerBinding(chord: combo, action: .shortcut1))
  expect(
    removed.contains(where: { $0.chord == ControllerChord(buttons: [.south]) }),
    "a combo should replace an ambiguous single-button prefix"
  )
  expect(mapping.action(for: combo) == .shortcut1, "the combo should resolve to its action")
  let data = try! JSONEncoder().encode(mapping)
  let decoded = try! JSONDecoder().decode(ControllerMapping.self, from: data)
  expect(decoded == mapping, "combo mappings should persist losslessly")
}

testComboMappingPersistsAndReplacesAmbiguousPrefixes()

func testControllerFamiliesUsePhysicalFaceButtonLabels() {
  expect(
    ControllerPresentation.label(for: .south, family: .playStation) == "Cross",
    "PlayStation south should be Cross"
  )
  expect(
    ControllerPresentation.label(for: .south, family: .xbox) == "A",
    "Xbox south should be A"
  )
  expect(
    ControllerPresentation.label(for: .south, family: .nintendo) == "B",
    "Nintendo south should be B"
  )
  expect(
    Set(ControllerButton.professionalButtons) == Set([
      .rightPaddle1, .leftPaddle1, .rightPaddle2, .leftPaddle2,
    ]),
    "professional controller paddles should be recordable inputs"
  )
}

testControllerFamiliesUsePhysicalFaceButtonLabels()

func testBindingResolverEmitsOnePressAndOneReleaseForAChord() {
  let combo = ControllerChord(buttons: [.leftShoulder, .south])!
  let mapping = ControllerMapping(bindings: [
    ControllerBinding(chord: combo, action: .pushToTalk)
  ])
  var resolver = ControllerBindingResolver()
  expect(
    resolver.process(button: .leftShoulder, pressed: true, mapping: mapping).isEmpty,
    "an incomplete chord should not trigger"
  )
  let pressed = resolver.process(button: .south, pressed: true, mapping: mapping)
  expect(
    pressed == [ControllerActionTransition(chord: combo, action: .pushToTalk, pressed: true)],
    "completing a chord should emit exactly one press"
  )
  expect(
    resolver.process(button: .south, pressed: true, mapping: mapping).isEmpty,
    "a repeated down event should not retrigger an active chord"
  )
  let released = resolver.process(button: .leftShoulder, pressed: false, mapping: mapping)
  expect(
    released == [ControllerActionTransition(chord: combo, action: .pushToTalk, pressed: false)],
    "breaking a chord should emit exactly one release"
  )
}

testBindingResolverEmitsOnePressAndOneReleaseForAChord()

func testPushToTalkDoesNotDependOnDesktopControlInjection() {
  expect(
    !ControllerAction.pushToTalk.requiresDesktopControls,
    "controller PTT should remain available while mouse injection is disabled"
  )
  expect(
    ControllerAction.primaryClick.requiresDesktopControls,
    "mouse clicks must remain gated by the desktop control switch"
  )
  expect(
    ControllerAction.shortcut1.requiresDesktopControls,
    "external keyboard shortcuts must remain gated by the desktop control switch"
  )
}

testPushToTalkDoesNotDependOnDesktopControlInjection()

func testVoiceSessionPoliciesCoverPermissionRefreshAndFinalization() {
  expect(
    !VoiceSessionPolicy.canBeginAfterEnvironmentRefresh(hasPressOwner: false),
    "recognition must not start after permission refresh removed its PTT owner"
  )
  expect(
    VoiceSessionPolicy.canBeginAfterEnvironmentRefresh(hasPressOwner: true),
    "a still-held PTT owner should be allowed to start recognition"
  )
  expect(
    VoiceSessionPolicy.isActiveForReconnect(isListening: false, isFinalizing: true),
    "the final recognition commit window is still an active voice session"
  )
}

testVoiceSessionPoliciesCoverPermissionRefreshAndFinalization()

func testPermissionDiagnosticsEmitOnlyTheInitialOrChangedSnapshot() {
  var tracker = PermissionDiagnosticTracker()
  let authorized = PermissionDiagnosticSnapshot(
    accessibilityGranted: true,
    microphoneRawValue: 3,
    speechRawValue: 3
  )
  expect(
    tracker.recordIfChanged(authorized) == authorized,
    "the initial permission snapshot should be observable"
  )
  expect(
    tracker.recordIfChanged(authorized) == nil,
    "unchanged permission polling must not spam the unified log"
  )
  let microphoneDenied = PermissionDiagnosticSnapshot(
    accessibilityGranted: true,
    microphoneRawValue: 2,
    speechRawValue: 3
  )
  expect(
    tracker.recordIfChanged(microphoneDenied) == microphoneDenied,
    "a changed permission should emit one new diagnostic snapshot"
  )
  expect(
    authorized.logMessage
      == "permission_snapshot accessibility=1 microphone=3 speech=3",
    "the diagnostic log must contain status values only"
  )
}

testPermissionDiagnosticsEmitOnlyTheInitialOrChangedSnapshot()

func testSafetyChordIsStopOnlyOrderIndependentAndFullyReserved() {
  var playStationTracker = SafetyChordTracker()
  expect(
    !playStationTracker.process(
      button: .touchpad,
      pressed: true,
      family: .playStation,
      now: 10
    ),
    "the first safety button should only arm the chord"
  )
  expect(
    playStationTracker.process(
      button: .start,
      pressed: true,
      family: .playStation,
      now: 10.5
    ),
    "PlayStation safety chord should work when touchpad is pressed first"
  )

  var xboxTracker = SafetyChordTracker()
  expect(
    !xboxTracker.process(button: .back, pressed: true, family: .xbox, now: 20),
    "Xbox Back should arm the safety chord"
  )
  expect(
    xboxTracker.process(button: .start, pressed: true, family: .xbox, now: 21),
    "Xbox Start+Back safety chord should work in either press order"
  )

  let safetySuperset = ControllerChord(buttons: [.start, .touchpad, .leftShoulder])!
  expect(
    SafetyChordPolicy.isReserved(safetySuperset, family: .playStation),
    "a mapping containing the fixed safety pair must be rejected as unreachable"
  )
  expect(
    SafetyChordPolicy.isReserved(
      ControllerChord(buttons: [.start, .back])!,
      family: .playStation
    ),
    "global mappings must reserve the Xbox/Switch safety pair while PlayStation is connected"
  )
  expect(
    SafetyChordPolicy.isReserved(
      ControllerChord(buttons: [.start, .touchpad])!,
      family: .xbox
    ),
    "global mappings must reserve the PlayStation safety pair while Xbox is connected"
  )
}

testSafetyChordIsStopOnlyOrderIndependentAndFullyReserved()

func testDualSenseUSBAudioAllowsABoundedControllerReconnect() {
  let controllerMic = AudioInputDevice(
    id: 700,
    name: "DualSense Wireless Controller",
    manufacturer: "Sony Interactive Entertainment",
    isDefault: false,
    transport: .usb
  )
  let identity = ControllerIdentity(family: .playStation, vendorID: 0x054C, productID: 0x0CE6)
  expect(controllerMic.isControllerRoutedUSB, "the enumerated DualSense USB input should be recognized")
  expect(
    ControllerReconnectPolicy.shouldWait(
      hasActiveVoiceSession: true,
      selectedAudioDevice: controllerMic,
      connection: .wired,
      controller: identity
    ),
    "starting wired DualSense audio should tolerate one bounded HID re-enumeration"
  )
  expect(
    ControllerReconnectPolicy.canResume(expected: identity, candidate: identity),
    "the same non-serial controller identity should resume after re-enumeration"
  )
  expect(
    ControllerReconnectPolicy.shouldWait(
      hasActiveVoiceSession: true,
      selectedAudioDevice: controllerMic,
      connection: .unknown,
      controller: identity
    ),
    "USB controller audio should prove a wired route when SDL reports unknown transport"
  )
  expect(
    !ControllerReconnectPolicy.shouldWait(
      hasActiveVoiceSession: true,
      selectedAudioDevice: controllerMic,
      connection: .wireless,
      controller: identity
    ),
    "an explicitly wireless controller must not enter the USB HID reconnect grace"
  )
  expect(
    ControllerReconnectPolicy.canMigrateAudioRoute(connection: .unknown),
    "the confirmed USB audio route should survive an unknown SDL transport"
  )
  expect(
    !ControllerReconnectPolicy.canMigrateAudioRoute(connection: .wireless),
    "an explicitly wireless route must not be treated as controller USB audio"
  )
}

testDualSenseUSBAudioAllowsABoundedControllerReconnect()

func testUnrelatedUSBMicrophoneDoesNotMaskARealDisconnect() {
  let genericUSB = AudioInputDevice(
    id: 701,
    name: "Studio USB Mic",
    manufacturer: "Example Audio",
    isDefault: false,
    transport: .usb
  )
  let identity = ControllerIdentity(family: .playStation, vendorID: 0x054C, productID: 0x0CE6)
  expect(
    !ControllerReconnectPolicy.shouldWait(
      hasActiveVoiceSession: true,
      selectedAudioDevice: genericUSB,
      connection: .wired,
      controller: identity
    ),
    "an unrelated USB microphone must not hide a real controller unplug"
  )
}

testUnrelatedUSBMicrophoneDoesNotMaskARealDisconnect()

func testAudioRefreshGateCoalescesBackgroundCatalogReads() {
  var gate = AudioRefreshGate()
  expect(gate.begin(), "the first audio catalog refresh should start")
  expect(!gate.begin(), "a second catalog refresh must not overlap the first")
  gate.end()
  expect(gate.begin(), "the gate should reopen after applying a completed refresh")
}

testAudioRefreshGateCoalescesBackgroundCatalogReads()

func testManualVoiceDeliveryRequiresCompletedTextAndAnIdleSession() {
  expect(
    VoiceManualDeliveryPolicy.deliverableText(
      " 重新发送这段文字 ",
      isListening: false,
      isFinalizing: false,
      deliveryInProgress: false
    ) == " 重新发送这段文字 ",
    "a completed transcript should remain available for an explicit external retry"
  )
  expect(
    VoiceManualDeliveryPolicy.deliverableText(
      "   \n",
      isListening: false,
      isFinalizing: false,
      deliveryInProgress: false
    ) == nil,
    "blank preview text must never be injected"
  )
  expect(
    VoiceManualDeliveryPolicy.deliverableText(
      "尚未完成",
      isListening: true,
      isFinalizing: false,
      deliveryInProgress: false
    ) == nil,
    "manual delivery must not race a live recognition session"
  )
  expect(
    VoiceManualDeliveryPolicy.deliverableText(
      "正在收尾",
      isListening: false,
      isFinalizing: true,
      deliveryInProgress: false
    ) == nil,
    "manual delivery must wait for recognition finalization"
  )
  expect(
    VoiceManualDeliveryPolicy.deliverableText(
      "自动写入仍在重试",
      isListening: false,
      isFinalizing: false,
      deliveryInProgress: true
    ) == nil,
    "manual delivery must not race an automatic or previous delivery attempt"
  )
}

testManualVoiceDeliveryRequiresCompletedTextAndAnIdleSession()

func testDefaultStickResponseMovesWithinFirstDisplayFrame() {
  var filter = StickMotionFilter()
  let deltaTime = 1.0 / 240.0
  var distance = 0.0
  for tick in 1...4 {
    let vector = filter.update(
      x: 0.20,
      y: 0,
      deadZone: ControlMath.stickDeadZone,
      responseExponent: ControlMath.defaultStickResponseExponent,
      responseTime: ControlMath.defaultStickSmoothingTime,
      deltaTime: deltaTime
    )
    distance += ControlMath.integratedStickPointerDelta(
      x: vector.x,
      y: vector.y,
      gain: 1,
      maximumSpeed: ControlMath.stickPointerMaximumSpeed,
      holdDuration: Double(tick) * deltaTime,
      accelerationDuration: 1.6,
      maximumBoost: 2.2,
      deltaTime: deltaTime
    ).x
  }
  expect(
    distance >= 1.5,
    "a light left-stick push should become visible within the first 60 Hz display frame"
  )
}

testDefaultStickResponseMovesWithinFirstDisplayFrame()

func testContinuousScrollDoesNotWaitForAnIntegerPixel() {
  let delta = ControlMath.continuousScrollDelta(
    axis: 0.20,
    deadZone: ControlMath.scrollStickDeadZone,
    gain: 10,
    deltaTime: 1.0 / 240.0
  )
  expect(delta != 0, "a light right-stick push should scroll on its first sampled frame")
  expect(abs(delta) < 1, "a light 240 Hz sample should retain its fractional pixel precision")
}

testContinuousScrollDoesNotWaitForAnIntegerPixel()

func testContinuousScrollEventPreservesFractionalPixels() {
  var accumulator = ContinuousScrollAccumulator()
  let sample = accumulator.update(precisePixels: -0.125)
  expect(
    sample.pointPixels == 0,
    "a fractional sample must not be inflated into an early full-point impulse"
  )
  expect(
    abs(sample.precisePixels + 0.125) < 0.000_1,
    "the point impulse must retain the original precise delta"
  )
  guard let event = ContinuousScrollEventFactory.make(sample: sample) else {
    expect(false, "continuous scroll event creation should succeed")
    return
  }
  expect(
    abs(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) + 0.125) < 0.000_1,
    "continuous scroll events should retain a signed fractional fixed-point delta"
  )
  expect(
    event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 0,
    "the compatibility point field should wait until cumulative motion reaches half a point"
  )
  guard let appKitEvent = NSEvent(cgEvent: event) else {
    expect(false, "AppKit should accept the continuous CoreGraphics scroll event")
    return
  }
  expect(
    appKitEvent.hasPreciseScrollingDeltas,
    "AppKit should expose the event as precise pixel scrolling"
  )
  expect(
    abs(appKitEvent.deltaY + 0.125) < 0.000_1,
    "the event's precise delta should remain fractional for compatible applications"
  )
  expect(
    appKitEvent.scrollingDeltaY == 0,
    "AppKit compatibility output must avoid a one-point startup spike"
  )
}

testContinuousScrollEventPreservesFractionalPixels()

func testContinuousScrollPointImpulsesPreserveLongTermDistance() {
  var accumulator = ContinuousScrollAccumulator()
  var pointTotal: Int32 = 0
  for _ in 0..<16 {
    pointTotal += accumulator.update(precisePixels: -0.125).pointPixels
  }
  expect(
    pointTotal == -2,
    "first-frame point compensation should repay itself and preserve long-term distance"
  )
  expect(
    accumulator.update(precisePixels: 0).pointPixels == 0,
    "centering the stick should reset the point accumulator"
  )
}

testContinuousScrollPointImpulsesPreserveLongTermDistance()

func testContinuousScrollPointImpulsesRemainEvenAtLowSpeed() {
  var accumulator = ContinuousScrollAccumulator()
  var impulseIndices: [Int] = []
  for index in 0..<32 {
    if accumulator.update(precisePixels: -0.125).pointPixels != 0 {
      impulseIndices.append(index)
    }
  }
  expect(
    impulseIndices == [3, 11, 19, 27],
    "constant precise scroll should create evenly spaced compatibility impulses"
  )
}

testContinuousScrollPointImpulsesRemainEvenAtLowSpeed()

func testContinuousScrollAccumulatorRespondsToDirectionChanges() {
  var accumulator = ContinuousScrollAccumulator()
  expect(
    accumulator.update(precisePixels: -0.5).pointPixels == -1,
    "half-point downward motion should produce one compatibility point"
  )
  expect(
    accumulator.update(precisePixels: 0.5).pointPixels == 1,
    "reversing the stick should discard old point debt at the same threshold"
  )

  accumulator.reset()
  for _ in 0..<7 {
    expect(
      accumulator.update(precisePixels: -0.0625).pointPixels == 0,
      "sub-threshold precision should not create a one-point noise impulse"
    )
  }
  expect(
    accumulator.update(precisePixels: -0.0625).pointPixels == -1,
    "accumulated half-point motion should become one compatibility point"
  )
}

testContinuousScrollAccumulatorRespondsToDirectionChanges()

func testContinuousScrollStartupCompensationHasBoundedShortGestureError() {
  var accumulator = ContinuousScrollAccumulator()
  let initial = accumulator.update(precisePixels: -0.125)
  let stopped = accumulator.update(precisePixels: 0)
  let pointDistance = Double(initial.pointPixels + stopped.pointPixels)
  expect(
    abs(pointDistance - initial.precisePixels) < 1,
    "an immediate release may quantize, but its point error must stay below one point"
  )

  let downward = accumulator.update(precisePixels: -0.25)
  let reversed = accumulator.update(precisePixels: 0.125)
  let preciseDistance = downward.precisePixels + reversed.precisePixels
  let reversedPointDistance = Double(downward.pointPixels + reversed.pointPixels)
  expect(
    abs(reversedPointDistance - preciseDistance) < 1,
    "an asymmetric direction reversal must discard at most a sub-point remainder"
  )
}

testContinuousScrollStartupCompensationHasBoundedShortGestureError()

func testExternalUnicodeFallbackUsesGuardedGlobalHIDRoute() {
  expect(
    TextInsertionPolicy.unicodeEventPostingRoute(
      confirmedExternalTarget: false,
      focusReadiness: nil,
      secureInputEnabled: false
    ) == .refused,
    "the global HID route must never target an unconfirmed external editor"
  )
  expect(
    TextInsertionPolicy.unicodeEventPostingRoute(
      confirmedExternalTarget: true,
      focusReadiness: .ready,
      secureInputEnabled: false
    ) == .globalHID,
    "a freshly confirmed external editor should receive the browser-compatible HID route"
  )
  expect(
    TextInsertionPolicy.unicodeEventPostingRoute(
      confirmedExternalTarget: true,
      focusReadiness: .retry,
      secureInputEnabled: false
    ) == .refused,
    "the HID route must refuse a stale or changing external focus"
  )
  expect(
    TextInsertionPolicy.unicodeEventPostingRoute(
      confirmedExternalTarget: true,
      focusReadiness: .ready,
      secureInputEnabled: true
    ) == .refused,
    "Unicode dispatch must recheck Secure Input at the final posting boundary"
  )
}

testExternalUnicodeFallbackUsesGuardedGlobalHIDRoute()

func testDisplaySynchronizedMotionCombinesInputSamplesWithoutLosingDistance() {
  var accumulator = DisplaySynchronizedMotionAccumulator()
  accumulator.add(pointer: CGPoint(x: 0.08, y: -0.04), scrollPixels: -0.20)
  accumulator.add(pointer: CGPoint(x: 0.09, y: -0.05), scrollPixels: -0.25)

  let frame = accumulator.drain()
  expect(
    abs(frame.pointer.x - 0.17) < 0.000_001
      && abs(frame.pointer.y + 0.09) < 0.000_001,
    "two 240 Hz pointer samples should become one distance-preserving display-frame move"
  )
  expect(
    abs(frame.scrollPixels + 0.45) < 0.000_001,
    "display-frame scroll should preserve every precise input sample"
  )
  expect(accumulator.drain() == .zero, "draining a display frame must clear pending motion")
}

testDisplaySynchronizedMotionCombinesInputSamplesWithoutLosingDistance()

func testDisplaySynchronizedMotionResetDropsStaleDirectionDebt() {
  var accumulator = DisplaySynchronizedMotionAccumulator()
  accumulator.add(pointer: CGPoint(x: 0.25, y: 0), scrollPixels: -0.125)
  accumulator.reset()
  accumulator.add(pointer: CGPoint(x: -0.10, y: 0), scrollPixels: 0.25)

  let frame = accumulator.drain()
  expect(
    abs(frame.pointer.x + 0.10) < 0.000_001 && abs(frame.scrollPixels - 0.25) < 0.000_001,
    "reset motion must not leak an old direction into the next display frame"
  )
}

testDisplaySynchronizedMotionResetDropsStaleDirectionDebt()

func testDisplayFramePreservesScrollEndAfterPendingDistance() {
  var accumulator = DisplaySynchronizedMotionAccumulator()
  var scrollAccumulator = ContinuousScrollAccumulator()
  accumulator.add(pointer: .zero, scrollPixels: -0.125)
  accumulator.add(
    pointer: .zero,
    scrollPixels: 0,
    scrollGestureEnded: true
  )

  let frame = accumulator.drain()
  expect(
    abs(frame.scrollPixels + 0.125) < 0.000_001,
    "a final zero sample must not erase pending precise scroll distance"
  )
  expect(
    frame.scrollGestureEnded,
    "a scroll end marker must survive aggregation with an earlier nonzero sample"
  )
  let finalSample = scrollAccumulator.update(precisePixels: frame.scrollPixels)
  if frame.scrollGestureEnded { scrollAccumulator.reset() }
  expect(
    abs(finalSample.precisePixels + 0.125) < 0.000_001,
    "the final precise distance must be emitted before the scroll state is reset"
  )
}

testDisplayFramePreservesScrollEndAfterPendingDistance()

func testUnicodeTextEventsArePlannedPerComposedCharacter() {
  let text = "你好e\u{301}🙂"
  let chunks = UnicodeTextEventPlanner.chunks(for: text)
  expect(chunks.joined() == text, "Unicode event chunks must reconstruct the transcript exactly")
  expect(
    chunks == text.map(String.init),
    "each keyboard event must preserve one complete grapheme instead of sending the whole transcript"
  )
  expect(
    chunks.allSatisfy { !$0.utf16.isEmpty },
    "Unicode delivery must not schedule empty keyboard events"
  )
}

testUnicodeTextEventsArePlannedPerComposedCharacter()

func testPartialUnicodeDeliveryRetriesOnlyTheUndeliveredSuffix() {
  let chunks = UnicodeTextEventPlanner.chunks(for: "甲乙丙丁")
  expect(
    UnicodeDeliveryProgress.remainingText(chunks: chunks, sentCount: 2) == "丙丁",
    "a partial delivery retry must not duplicate the prefix already posted to the target"
  )
  expect(
    UnicodeDeliveryProgress.remainingText(chunks: chunks, sentCount: 99).isEmpty,
    "a completed delivery must not retain phantom retry text"
  )
}

testPartialUnicodeDeliveryRetriesOnlyTheUndeliveredSuffix()

func testAccessibilityWriteSuccessRequiresValueReadback() {
  expect(
    AccessibilityTextWriteVerification.evaluate(
      before: "hello ",
      expected: "hello world",
      after: "hello world"
    ) == .confirmed,
    "AX success is confirmed only when the target value matches the expected edit"
  )
  expect(
    AccessibilityTextWriteVerification.evaluate(
      before: "hello ",
      expected: "hello world",
      after: "hello "
    ) == .unchanged,
    "an unchanged AX value must not be reported as a confirmed insertion"
  )
  expect(
    AccessibilityTextWriteVerification.evaluate(
      before: nil,
      expected: nil,
      after: nil
    ) == .unverifiable,
    "a target without readable value/range cannot produce a confirmed AX result"
  )
}

testAccessibilityWriteSuccessRequiresValueReadback()

func testShortcutEditorsWrapBeforeControlsOverlap() {
  expect(
    MappingLayoutPolicy.shortcutColumnCount(for: 700) == 2,
    "the mapping card should use two shortcut columns at the app's normal content width"
  )
  expect(
    MappingLayoutPolicy.shortcutColumnCount(for: 420) == 1,
    "a narrow mapping card should stack shortcut editors"
  )
}

testShortcutEditorsWrapBeforeControlsOverlap()

func testSparkleConfigurationFailsClosed() {
  let configured: [String: Any] = [
    "SUFeedURL": "https://github.com/tonycoder-hub/helm-dualsense/releases/latest/download/appcast.xml",
    "SUPublicEDKey": "public-key",
    "SURequireSignedFeed": true,
    "SUVerifyUpdateBeforeExtraction": true,
    "SUSignedFeedFailureExpirationInterval": 0,
    "SUEnableAutomaticChecks": false,
  ]
  expect(
    SparkleUpdateConfigurationPolicy.isConfigured(info: configured),
    "the updater should start only when every signed-feed safeguard is present"
  )

  for missingKey in [
    "SURequireSignedFeed",
    "SUVerifyUpdateBeforeExtraction",
    "SUSignedFeedFailureExpirationInterval",
  ] {
    var incomplete = configured
    incomplete.removeValue(forKey: missingKey)
    expect(
      !SparkleUpdateConfigurationPolicy.isConfigured(info: incomplete),
      "the updater must fail closed when \(missingKey) is absent"
    )
  }

  var expiringFailure = configured
  expiringFailure["SUSignedFeedFailureExpirationInterval"] = 1
  expect(
    !SparkleUpdateConfigurationPolicy.isConfigured(info: expiringFailure),
    "a signed-feed validation failure must never expire into an unsigned fallback"
  )
}

testSparkleConfigurationFailsClosed()

let audioInputs = AudioInputCatalog.devices()
expect(!audioInputs.isEmpty, "at least one Mac-supported audio input should be discoverable")
expect(audioInputs.contains(where: { $0.isDefault }), "default audio input should be identified")

print("CONTROL_MATH_AND_AUDIO_TESTS=PASS inputs=\(audioInputs.count)")

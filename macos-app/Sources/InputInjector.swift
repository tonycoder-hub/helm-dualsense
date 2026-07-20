import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum TextInsertionResult {
  case inserted(String)
  case dispatched(String)
  case retryable(String)
  case refused(String)
}

enum TextInsertionPreparation {
  case result(TextInsertionResult)
  case unicodeChunks([String])
}

enum UnicodeChunkPostResult {
  case posted
  case retryable(String)
  case refused(String)
}

struct ExternalTextFocusSnapshot {
  let processIdentifier: Int32
  let role: String
  let subrole: String
  fileprivate let element: AXUIElement
}

enum InputInjector {
  private static let pointerStateLock = NSLock()
  private static var pointerTarget: CGPoint?
  private static var pointerDisplayBounds = [CGDisplayBounds(CGMainDisplayID())]

  static func accessibilityTrusted(prompt: Bool = false) -> Bool {
    guard prompt else { return AXIsProcessTrusted() }
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
    return AXIsProcessTrustedWithOptions(options as CFDictionary)
  }

  @discardableResult
  static func movePointer(
    dx: Double,
    dy: Double,
    leftButtonDown: Bool,
    rightButtonDown: Bool
  ) -> Bool {
    pointerStateLock.lock()
    defer { pointerStateLock.unlock() }
    guard let location = pointerTarget ?? CGEvent(source: nil)?.location else { return false }
    let displayBounds = pointerDisplayBounds
    let eventType: CGEventType
    let eventButton: CGMouseButton
    if leftButtonDown {
      eventType = .leftMouseDragged
      eventButton = .left
    } else if rightButtonDown {
      eventType = .rightMouseDragged
      eventButton = .right
    } else {
      eventType = .mouseMoved
      eventButton = .left
    }
    guard
      let event = PointerEventFactory.make(
        origin: location,
        delta: CGPoint(x: dx, y: dy),
        displayBounds: displayBounds,
        mouseType: eventType,
        mouseButton: eventButton
      )
    else { return false }
    event.post(tap: .cghidEventTap)
    pointerTarget = event.location
    return true
  }

  static func beginPointerSession() {
    let displayBounds = readActiveDisplayBounds()
    let location = CGEvent(source: nil)?.location
    pointerStateLock.lock()
    pointerDisplayBounds = displayBounds
    pointerTarget = location
    pointerStateLock.unlock()
  }

  static func endPointerSession() {
    pointerStateLock.lock()
    pointerTarget = nil
    pointerStateLock.unlock()
  }

  static func mouseButton(_ button: CGMouseButton, pressed: Bool) {
    guard let location = CGEvent(source: nil)?.location else { return }
    PointerEventFactory.makeButtonEvent(
      location: location,
      button: button,
      pressed: pressed
    )?.post(tap: .cghidEventTap)
  }

  @discardableResult
  static func scroll(sample: ContinuousScrollSample) -> Bool {
    guard let event = ContinuousScrollEventFactory.make(sample: sample) else { return false }
    event.post(tap: .cghidEventTap)
    return true
  }

  static func page(direction: Int32) {
    CGEvent(
      scrollWheelEvent2Source: nil,
      units: .line,
      wheelCount: 1,
      wheel1: direction * 8,
      wheel2: 0,
      wheel3: 0
    )?.post(tap: .cghidEventTap)
  }

  static func captureExternalTextFocus(
    processIdentifier: Int32,
    allowsApplicationFallback: Bool = false
  ) -> ExternalTextFocusSnapshot? {
    guard accessibilityTrusted(), processIdentifier > 0,
      processIdentifier != ProcessInfo.processInfo.processIdentifier,
      let element = focusedElement(
        for: processIdentifier,
        allowsApplicationFallback: allowsApplicationFallback
      ),
      self.processIdentifier(of: element) == processIdentifier
    else { return nil }
    var roleValue: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(
      element,
      kAXRoleAttribute as CFString,
      &roleValue
    )
    var subroleValue: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(
      element,
      kAXSubroleAttribute as CFString,
      &subroleValue
    )
    return ExternalTextFocusSnapshot(
      processIdentifier: processIdentifier,
      role: roleValue as? String ?? "unknown",
      subrole: subroleValue as? String ?? "none",
      element: element
    )
  }

  @discardableResult
  static func restoreExternalTextFocus(_ snapshot: ExternalTextFocusSnapshot) -> Bool {
    guard accessibilityTrusted(), snapshot.processIdentifier > 0,
      snapshot.processIdentifier != ProcessInfo.processInfo.processIdentifier,
      processIdentifier(of: snapshot.element) == snapshot.processIdentifier
    else { return false }
    if externalTextFocusReadiness(snapshot) == .ready { return true }
    guard
      AXUIElementSetAttributeValue(
        snapshot.element,
        kAXFocusedAttribute as CFString,
        kCFBooleanTrue
      ) == .success,
      let current = systemWideFocusedElement(for: snapshot.processIdentifier)
    else { return false }
    return CFEqual(current, snapshot.element)
  }

  static func externalTextFocusReadiness(
    _ snapshot: ExternalTextFocusSnapshot
  ) -> ExternalTextFocusReadiness {
    guard processIdentifier(of: snapshot.element) == snapshot.processIdentifier,
      let currentElement = systemWideFocusedElement(for: snapshot.processIdentifier)
    else { return .retry }
    let readiness = externalFocusReadiness(
      expectedProcessIdentifier: snapshot.processIdentifier,
      focusedElement: currentElement
    )
    guard readiness == .ready else { return readiness }
    return CFEqual(currentElement, snapshot.element) ? .ready : .retry
  }

  static func sendShortcut(_ shortcut: KeyboardShortcutDefinition) -> Bool {
    guard accessibilityTrusted(), !HelmSecureInputEnabled() else {
      return false
    }
    let plan = KeyboardShortcutEventPlanner.plan(for: shortcut)
    guard !plan.isEmpty else { return false }

    var events: [CGEvent] = []
    for step in plan {
      guard let event = CGEvent(
        keyboardEventSource: nil,
        virtualKey: CGKeyCode(step.virtualKeyCode),
        keyDown: step.pressed
      ) else { return false }
      event.flags = flags(forModifierVirtualKeyCodes: step.activeModifierVirtualKeyCodes)
      events.append(event)
    }
    events.forEach { $0.post(tap: .cghidEventTap) }
    return true
  }

  static func applyModifierKeyTransitions(
    _ transitions: [ModifierKeyTransition]
  ) -> Bool {
    guard !transitions.isEmpty else { return true }
    if transitions.contains(where: \.pressed) {
      guard accessibilityTrusted(), !HelmSecureInputEnabled() else { return false }
    }

    var events: [CGEvent] = []
    for transition in transitions {
      guard
        let event = CGEvent(
          keyboardEventSource: nil,
          virtualKey: CGKeyCode(transition.virtualKeyCode),
          keyDown: transition.pressed
        )
      else { return false }
      event.flags = flags(forModifierVirtualKeyCodes: transition.activeModifierVirtualKeyCodes)
      events.append(event)
    }
    events.forEach { $0.post(tap: .cghidEventTap) }
    return true
  }

  private static func flags(
    forModifierVirtualKeyCodes codes: [UInt16]
  ) -> CGEventFlags {
    var flags: CGEventFlags = []
    if codes.contains(where: { $0 == 59 || $0 == 62 }) { flags.insert(.maskControl) }
    if codes.contains(where: { $0 == 58 || $0 == 61 }) { flags.insert(.maskAlternate) }
    if codes.contains(where: { $0 == 56 || $0 == 60 }) { flags.insert(.maskShift) }
    if codes.contains(where: { $0 == 55 || $0 == 54 }) { flags.insert(.maskCommand) }
    return flags
  }

  static func prepareTextInsertion(
    _ text: String,
    focusSnapshot: ExternalTextFocusSnapshot
  ) -> TextInsertionPreparation {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .result(.refused("没有可写入的识别文本"))
    }
    guard accessibilityTrusted() else {
      return .result(.refused("缺少辅助功能权限，文本只保留在 GripPilot 中"))
    }
    let secureInputEnabled = HelmSecureInputEnabled()
    guard focusSnapshot.processIdentifier > 0,
      focusSnapshot.processIdentifier != ProcessInfo.processInfo.processIdentifier
    else { return .result(.refused("外部文本目标无效")) }
    switch externalTextFocusReadiness(focusSnapshot) {
    case .ready: break
    case .retry:
      return .result(.retryable("捕获的外部文本框焦点尚未恢复"))
    case .refused:
      return .result(.refused("外部文本目标无效"))
    }
    let element = focusSnapshot.element

    var subroleValue: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(
      element,
      kAXSubroleAttribute as CFString,
      &subroleValue
    )
    let secureField = (subroleValue as? String) == (kAXSecureTextFieldSubrole as String)

    var roleValue: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(
      element,
      kAXRoleAttribute as CFString,
      &roleValue
    )
    let focusedRole = roleValue as? String

    var settable = DarwinBoolean(false)
    let settableStatus = AXUIElementIsAttributeSettable(
      element,
      kAXSelectedTextAttribute as CFString,
      &settable
    )
    let beforeState = accessibilityTextState(for: element)
    var decision = TextInsertionPolicy.decision(
      secureInputEnabled: secureInputEnabled,
      secureField: secureField,
      focusedRole: focusedRole,
      selectedTextSettable: settableStatus == .success && settable.boolValue,
      selectedTextStateReadable: beforeState != nil,
      confirmedExternalTarget: true
    )

    if decision == .accessibilitySelectedText {
      guard externalTextFocusReadiness(focusSnapshot) == .ready else {
        return .result(.retryable("捕获的外部文本框焦点仍在切换"))
      }
      let expectedValue = beforeState.flatMap {
        replacingSelectedText(in: $0, with: text)
      }
      let status = AXUIElementSetAttributeValue(
        element,
        kAXSelectedTextAttribute as CFString,
        text as CFTypeRef
      )
      if status == .success {
        let afterValue = accessibilityTextState(for: element)?.value
        switch AccessibilityTextWriteVerification.evaluate(
          before: beforeState?.value,
          expected: expectedValue,
          after: afterValue
        ) {
        case .confirmed:
          return .result(.inserted("辅助功能直接写入并读回确认"))
        case .unchanged:
          break
        case .diverged:
          return .result(.dispatched("辅助功能写入已执行，但读回结果与预期不一致"))
        case .unverifiable:
          return .result(.dispatched("辅助功能写入已执行，但目标不支持读回确认"))
        }
      }
      decision = TextInsertionPolicy.decision(
        secureInputEnabled: secureInputEnabled,
        secureField: secureField,
        focusedRole: focusedRole,
        selectedTextSettable: false,
        selectedTextStateReadable: beforeState != nil,
        confirmedExternalTarget: true
      )
      if decision == .refused {
        return .result(.refused("文本写入失败（AX \(status.rawValue)）"))
      }
    }

    guard decision == .unicodeKeyboardEvents else {
      if secureInputEnabled {
        return .result(.refused("检测到系统安全输入，已拒绝写入"))
      }
      if secureField { return .result(.refused("安全文本框不允许语音写入")) }
      return .result(.refused("当前焦点不是可安全写入的文本框"))
    }

    let chunks = UnicodeTextEventPlanner.chunks(for: text)
    guard !chunks.isEmpty else {
      return .result(.refused("没有可写入的识别文本"))
    }
    return .unicodeChunks(chunks)
  }

  static func postUnicodeChunk(
    _ chunk: String,
    focusSnapshot: ExternalTextFocusSnapshot
  ) -> UnicodeChunkPostResult {
    guard !chunk.utf16.isEmpty else { return .refused("Unicode 字素为空") }
    guard accessibilityTrusted() else { return .refused("缺少辅助功能权限") }
    guard !HelmSecureInputEnabled() else {
      return .refused("检测到系统安全输入")
    }
    guard externalTextFocusReadiness(focusSnapshot) == .ready else {
      return .retryable("捕获的外部文本框已失去焦点")
    }
    guard
      TextInsertionPolicy.unicodeEventPostingRoute(
        confirmedExternalTarget: true,
        focusReadiness: .ready,
        secureInputEnabled: false
      ) == .globalHID,
      let events = UnicodeKeyboardEventFactory.make(chunk: chunk)
    else { return .refused("无法创建 Unicode 键盘事件") }
    guard !HelmSecureInputEnabled() else {
      return .refused("检测到系统安全输入")
    }
    guard externalTextFocusReadiness(focusSnapshot) == .ready else {
      return .retryable("捕获的外部文本框已失去焦点")
    }
    events.keyDown.post(tap: .cghidEventTap)
    events.keyUp.post(tap: .cghidEventTap)
    return .posted
  }

  private struct AccessibilityTextState {
    let value: String
    let selectedRange: CFRange
  }

  private static func accessibilityTextState(
    for element: AXUIElement
  ) -> AccessibilityTextState? {
    var valueReference: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element,
        kAXValueAttribute as CFString,
        &valueReference
      ) == .success,
      let value = valueReference as? String
    else { return nil }

    var rangeReference: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element,
        kAXSelectedTextRangeAttribute as CFString,
        &rangeReference
      ) == .success,
      let rangeReference,
      CFGetTypeID(rangeReference) == AXValueGetTypeID()
    else { return nil }
    let rangeValue = unsafeBitCast(rangeReference, to: AXValue.self)
    guard AXValueGetType(rangeValue) == .cfRange else { return nil }
    var selectedRange = CFRange()
    guard AXValueGetValue(rangeValue, .cfRange, &selectedRange) else { return nil }
    return AccessibilityTextState(value: value, selectedRange: selectedRange)
  }

  private static func replacingSelectedText(
    in state: AccessibilityTextState,
    with text: String
  ) -> String? {
    guard state.selectedRange.location >= 0, state.selectedRange.length >= 0 else {
      return nil
    }
    let value = state.value as NSString
    let range = NSRange(
      location: state.selectedRange.location,
      length: state.selectedRange.length
    )
    guard NSMaxRange(range) <= value.length else { return nil }
    return value.replacingCharacters(in: range, with: text)
  }

  private static func focusedElement(
    for processIdentifier: Int32,
    allowsApplicationFallback: Bool
  ) -> AXUIElement? {
    let systemWideElement = systemWideFocusedElement()
    let applicationElement = allowsApplicationFallback
      ? applicationFocusedElement(for: processIdentifier)
      : nil

    switch TextInsertionPolicy.focusedElementSource(
      expectedProcessIdentifier: processIdentifier,
      systemWideProcessIdentifier: systemWideElement.flatMap(processIdentifier(of:)),
      applicationProcessIdentifier: applicationElement.flatMap(processIdentifier(of:)),
      allowsApplicationFallback: allowsApplicationFallback
    ) {
    case .systemWide: return systemWideElement
    case .application: return applicationElement
    case .unavailable: return nil
    }
  }

  private static func systemWideFocusedElement(
    for expectedProcessIdentifier: Int32? = nil
  ) -> AXUIElement? {
    let systemWide = AXUIElementCreateSystemWide()
    var systemWideValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        systemWide,
        kAXFocusedUIElementAttribute as CFString,
        &systemWideValue
      ) == .success,
      let systemWideValue
    else { return nil }
    let element = unsafeBitCast(systemWideValue, to: AXUIElement.self)
    if let expectedProcessIdentifier,
      processIdentifier(of: element) != expectedProcessIdentifier
    {
      return nil
    }
    return element
  }

  private static func applicationFocusedElement(
    for processIdentifier: Int32
  ) -> AXUIElement? {
    let application = AXUIElementCreateApplication(pid_t(processIdentifier))
    var applicationValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        application,
        kAXFocusedUIElementAttribute as CFString,
        &applicationValue
      ) == .success,
      let applicationValue
    else { return nil }
    return unsafeBitCast(applicationValue, to: AXUIElement.self)
  }

  private static func processIdentifier(of element: AXUIElement) -> Int32? {
    var processIdentifier = pid_t(0)
    guard AXUIElementGetPid(element, &processIdentifier) == .success else { return nil }
    return Int32(processIdentifier)
  }

  private static func externalFocusReadiness(
    expectedProcessIdentifier: Int32,
    focusedElement: AXUIElement
  ) -> ExternalTextFocusReadiness {
    TextInsertionPolicy.externalFocusReadiness(
      expectedProcessIdentifier: expectedProcessIdentifier,
      helmProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
      frontmostProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier,
      focusedElementProcessIdentifier: processIdentifier(of: focusedElement)
    )
  }

  private static func readActiveDisplayBounds() -> [CGRect] {
    var displayCount: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &displayCount) == .success,
      displayCount > 0
    else { return [CGDisplayBounds(CGMainDisplayID())] }

    var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
    var writtenCount: UInt32 = 0
    let status = displays.withUnsafeMutableBufferPointer { buffer in
      CGGetActiveDisplayList(displayCount, buffer.baseAddress, &writtenCount)
    }
    guard status == .success, writtenCount > 0 else {
      return [CGDisplayBounds(CGMainDisplayID())]
    }
    return displays.prefix(Int(writtenCount)).map(CGDisplayBounds)
  }

  static func openAccessibilitySettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
      )
    else { return }
    NSWorkspace.shared.open(url)
  }

  static func openSoundSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")
    else {
      return
    }
    NSWorkspace.shared.open(url)
  }
}

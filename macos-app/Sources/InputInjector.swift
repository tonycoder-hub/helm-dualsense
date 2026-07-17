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

enum InputInjector {
  private static var pointerTarget: CGPoint?

  static func accessibilityTrusted(prompt: Bool = false) -> Bool {
    guard prompt else { return AXIsProcessTrusted() }
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
    return AXIsProcessTrustedWithOptions(options as CFDictionary)
  }

  static func movePointer(
    dx: Double,
    dy: Double,
    leftButtonDown: Bool,
    rightButtonDown: Bool
  ) {
    guard let location = pointerTarget ?? CGEvent(source: nil)?.location else { return }
    let bounds = CGDisplayBounds(CGMainDisplayID())
    let target = CGPoint(
      x: min(max(location.x + dx, bounds.minX), bounds.maxX - 1),
      y: min(max(location.y + dy, bounds.minY), bounds.maxY - 1)
    )
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
    CGEvent(
      mouseEventSource: nil,
      mouseType: eventType,
      mouseCursorPosition: target,
      mouseButton: eventButton
    )?.post(tap: .cghidEventTap)
    pointerTarget = target
  }

  static func beginPointerSession() {
    pointerTarget = CGEvent(source: nil)?.location
  }

  static func endPointerSession() {
    pointerTarget = nil
  }

  static func mouseButton(_ button: CGMouseButton, pressed: Bool) {
    guard let location = CGEvent(source: nil)?.location else { return }
    let type: CGEventType
    if button == .left {
      type = pressed ? .leftMouseDown : .leftMouseUp
    } else if button == .right {
      type = pressed ? .rightMouseDown : .rightMouseUp
    } else {
      return
    }
    CGEvent(
      mouseEventSource: nil,
      mouseType: type,
      mouseCursorPosition: location,
      mouseButton: button
    )?.post(tap: .cghidEventTap)
  }

  static func scroll(sample: ContinuousScrollSample) {
    ContinuousScrollEventFactory.make(sample: sample)?.post(tap: .cghidEventTap)
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

  static func insertAtFocusedTextElement(
    _ text: String,
    expectedProcessIdentifier: Int32? = nil
  ) -> TextInsertionResult {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .refused("没有可写入的识别文本")
    }
    guard accessibilityTrusted() else {
      return .refused("缺少辅助功能权限，文本只保留在 Helm 中")
    }
    let secureInputEnabled = HelmSecureInputEnabled()
    let helmProcessIdentifier = ProcessInfo.processInfo.processIdentifier
    let element: AXUIElement
    let confirmedExternalTarget: Bool
    if let expectedProcessIdentifier {
      guard expectedProcessIdentifier > 0,
        expectedProcessIdentifier != helmProcessIdentifier
      else { return .refused("外部文本目标无效") }
      guard let focusedElement = focusedElement(for: expectedProcessIdentifier) else {
        return .retryable("外部应用的文本焦点尚未就绪")
      }
      switch externalFocusReadiness(
        expectedProcessIdentifier: expectedProcessIdentifier,
        focusedElement: focusedElement
      ) {
      case .ready:
        element = focusedElement
        confirmedExternalTarget = true
      case .retry:
        return .retryable("外部应用的文本焦点尚未就绪")
      case .refused:
        return .refused("外部文本目标无效")
      }
    } else {
      let system = AXUIElementCreateSystemWide()
      var value: CFTypeRef?
      guard
        AXUIElementCopyAttributeValue(
          system,
          kAXFocusedUIElementAttribute as CFString,
          &value
        ) == .success, let value
      else {
        return .refused("当前没有可编辑的文本焦点")
      }
      element = unsafeBitCast(value, to: AXUIElement.self)
      confirmedExternalTarget = false
    }

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
    var decision = TextInsertionPolicy.decision(
      secureInputEnabled: secureInputEnabled,
      secureField: secureField,
      focusedRole: focusedRole,
      selectedTextSettable: settableStatus == .success && settable.boolValue,
      confirmedExternalTarget: confirmedExternalTarget
    )

    if decision == .accessibilitySelectedText {
      if let expectedProcessIdentifier {
        switch externalTargetStillFocused(
          expectedProcessIdentifier: expectedProcessIdentifier,
          originalElement: element
        ) {
        case .ready: break
        case .retry: return .retryable("外部应用的文本焦点仍在切换")
        case .refused: return .refused("外部文本目标无效")
        }
      }
      let status = AXUIElementSetAttributeValue(
        element,
        kAXSelectedTextAttribute as CFString,
        text as CFTypeRef
      )
      if status == .success { return .inserted("辅助功能直接写入") }
      decision = TextInsertionPolicy.decision(
        secureInputEnabled: secureInputEnabled,
        secureField: secureField,
        focusedRole: focusedRole,
        selectedTextSettable: false,
        confirmedExternalTarget: confirmedExternalTarget
      )
      if decision == .refused {
        return .refused("文本写入失败（AX \(status.rawValue)）")
      }
    }

    guard decision == .unicodeKeyboardEvents else {
      if secureInputEnabled { return .refused("检测到系统安全输入，已拒绝写入") }
      if secureField { return .refused("安全文本框不允许语音写入") }
      return .refused("当前焦点不是可安全写入的文本框")
    }

    guard
      let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
      let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
    else { return .refused("无法创建 Unicode 键盘事件") }
    let characters = Array(text.utf16)
    characters.withUnsafeBufferPointer { buffer in
      keyDown.keyboardSetUnicodeString(
        stringLength: buffer.count,
        unicodeString: buffer.baseAddress
      )
      keyUp.keyboardSetUnicodeString(
        stringLength: buffer.count,
        unicodeString: buffer.baseAddress
      )
    }

    var postingFocusReadiness: ExternalTextFocusReadiness?
    if let expectedProcessIdentifier {
      let readiness = externalTargetStillFocused(
        expectedProcessIdentifier: expectedProcessIdentifier,
        originalElement: element
      )
      postingFocusReadiness = readiness
      switch readiness {
      case .ready: break
      case .retry: return .retryable("外部应用的文本焦点仍在切换")
      case .refused: return .refused("外部文本目标无效")
      }
    }
    let secureInputAtPosting = HelmSecureInputEnabled()
    if secureInputAtPosting {
      return .refused("检测到系统安全输入，已拒绝写入")
    }
    guard
      TextInsertionPolicy.unicodeEventPostingRoute(
        confirmedExternalTarget: confirmedExternalTarget,
        focusReadiness: postingFocusReadiness,
        secureInputEnabled: secureInputAtPosting
      ) == .globalHID
    else {
      return .retryable("外部应用的文本焦点仍在切换")
    }
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
    return .dispatched(
      confirmedExternalTarget
        ? "Unicode 键盘事件（已锁定外部焦点）"
        : "Unicode 键盘事件"
    )
  }

  private static func focusedElement(for processIdentifier: Int32) -> AXUIElement? {
    let application = AXUIElementCreateApplication(pid_t(processIdentifier))
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        application,
        kAXFocusedUIElementAttribute as CFString,
        &value
      ) == .success, let value
    else { return nil }
    return unsafeBitCast(value, to: AXUIElement.self)
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

  private static func externalTargetStillFocused(
    expectedProcessIdentifier: Int32,
    originalElement: AXUIElement
  ) -> ExternalTextFocusReadiness {
    guard let currentElement = focusedElement(for: expectedProcessIdentifier) else { return .retry }
    let readiness = externalFocusReadiness(
      expectedProcessIdentifier: expectedProcessIdentifier,
      focusedElement: currentElement
    )
    guard readiness == .ready else { return readiness }
    return CFEqual(currentElement, originalElement) ? .ready : .retry
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

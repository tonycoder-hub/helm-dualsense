import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum TextInsertionResult {
  case inserted(String)
  case dispatched(String)
  case refused(String)
}

enum InputInjector {
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
    guard let location = CGEvent(source: nil)?.location else { return }
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

  static func scroll(pixels: Int32) {
    guard pixels != 0 else { return }
    CGEvent(
      scrollWheelEvent2Source: nil,
      units: .pixel,
      wheelCount: 1,
      wheel1: pixels,
      wheel2: 0,
      wheel3: 0
    )?.post(tap: .cghidEventTap)
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
    guard accessibilityTrusted(), !HelmSecureInputEnabled() else { return false }
    var flags: CGEventFlags = []
    if shortcut.command { flags.insert(.maskCommand) }
    if shortcut.option { flags.insert(.maskAlternate) }
    if shortcut.control { flags.insert(.maskControl) }
    if shortcut.shift { flags.insert(.maskShift) }

    guard
      let keyDown = CGEvent(
        keyboardEventSource: nil,
        virtualKey: CGKeyCode(shortcut.key.virtualKeyCode),
        keyDown: true
      ),
      let keyUp = CGEvent(
        keyboardEventSource: nil,
        virtualKey: CGKeyCode(shortcut.key.virtualKeyCode),
        keyDown: false
      )
    else { return false }
    keyDown.flags = flags
    keyUp.flags = flags
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
    return true
  }

  static func insertAtFocusedTextElement(_ text: String) -> TextInsertionResult {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .refused("没有可写入的识别文本")
    }
    guard accessibilityTrusted() else {
      return .refused("缺少辅助功能权限，文本只保留在 Helm 中")
    }
    let secureInputEnabled = HelmSecureInputEnabled()

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
    let element = unsafeBitCast(value, to: AXUIElement.self)

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
      selectedTextSettable: settableStatus == .success && settable.boolValue
    )

    if decision == .accessibilitySelectedText {
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
        selectedTextSettable: false
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
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
    return .dispatched("Unicode 键盘事件")
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

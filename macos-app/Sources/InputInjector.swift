import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum TextInsertionResult {
  case inserted
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

  static func insertAtFocusedTextElement(_ text: String) -> TextInsertionResult {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .refused("没有可写入的识别文本")
    }
    guard accessibilityTrusted() else {
      return .refused("缺少辅助功能权限，文本只保留在 Helm 中")
    }
    guard !HelmSecureInputEnabled() else {
      return .refused("检测到系统安全输入，已拒绝写入")
    }

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
    if AXUIElementCopyAttributeValue(
      element,
      kAXSubroleAttribute as CFString,
      &subroleValue
    ) == .success,
      let subrole = subroleValue as? String,
      subrole == (kAXSecureTextFieldSubrole as String)
    {
      return .refused("安全文本框不允许语音写入")
    }

    var settable = DarwinBoolean(false)
    guard
      AXUIElementIsAttributeSettable(
        element,
        kAXSelectedTextAttribute as CFString,
        &settable
      ) == .success, settable.boolValue
    else {
      return .refused("当前焦点不支持安全的选中文本写入")
    }

    let status = AXUIElementSetAttributeValue(
      element,
      kAXSelectedTextAttribute as CFString,
      text as CFTypeRef
    )
    return status == .success
      ? .inserted
      : .refused("文本写入失败（AX \(status.rawValue)）")
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

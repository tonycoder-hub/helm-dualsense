import CoreGraphics
import Foundation

struct UnicodeKeyboardEventPair {
  let keyDown: CGEvent
  let keyUp: CGEvent
}

enum UnicodeKeyboardEventFactory {
  private static let eventSource: CGEventSource? = {
    guard let source = CGEventSource(stateID: .hidSystemState) else { return nil }
    source.localEventsSuppressionInterval = 0
    return source
  }()

  static func make(chunk: String) -> UnicodeKeyboardEventPair? {
    guard !chunk.utf16.isEmpty, let eventSource,
      let keyDown = CGEvent(
        keyboardEventSource: eventSource,
        virtualKey: 0,
        keyDown: true
      ),
      let keyUp = CGEvent(
        keyboardEventSource: eventSource,
        virtualKey: 0,
        keyDown: false
    )
    else { return nil }

    keyDown.flags = []
    keyUp.flags = []
    let characters = Array(chunk.utf16)
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
    return UnicodeKeyboardEventPair(keyDown: keyDown, keyUp: keyUp)
  }
}

import Foundation

enum ShortcutKey: String, CaseIterable, Codable, Identifiable {
  case a
  case d
  case m
  case s
  case v
  case space
  case returnKey
  case f1
  case f2
  case f3
  case f4
  case f5
  case f6
  case f7
  case f8
  case f9
  case f10
  case f11
  case f12

  var id: String { rawValue }

  var title: String {
    switch self {
    case .space: return "Space"
    case .returnKey: return "Return"
    case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
      return rawValue.uppercased()
    default:
      return rawValue.uppercased()
    }
  }

  var virtualKeyCode: UInt16 {
    switch self {
    case .a: return 0
    case .d: return 2
    case .m: return 46
    case .s: return 1
    case .v: return 9
    case .space: return 49
    case .returnKey: return 36
    case .f1: return 122
    case .f2: return 120
    case .f3: return 99
    case .f4: return 118
    case .f5: return 96
    case .f6: return 97
    case .f7: return 98
    case .f8: return 100
    case .f9: return 101
    case .f10: return 109
    case .f11: return 103
    case .f12: return 111
    }
  }
}

struct KeyboardShortcutDefinition: Codable, Equatable {
  var key: ShortcutKey
  var command: Bool
  var option: Bool
  var control: Bool
  var shift: Bool

  var label: String {
    (control ? "⌃" : "")
      + (option ? "⌥" : "")
      + (shift ? "⇧" : "")
      + (command ? "⌘" : "")
      + key.title
  }
}

struct ControllerShortcutSettings: Codable, Equatable {
  var slot1: KeyboardShortcutDefinition
  var slot2: KeyboardShortcutDefinition
  var slot3: KeyboardShortcutDefinition

  static let standard = ControllerShortcutSettings(
    slot1: KeyboardShortcutDefinition(
      key: .d,
      command: false,
      option: true,
      control: true,
      shift: false
    ),
    slot2: KeyboardShortcutDefinition(
      key: .space,
      command: false,
      option: false,
      control: true,
      shift: false
    ),
    slot3: KeyboardShortcutDefinition(
      key: .space,
      command: true,
      option: false,
      control: false,
      shift: true
    )
  )
}

enum ControllerAction: String, CaseIterable, Codable, Identifiable {
  case none
  case primaryClick
  case secondaryClick
  case pageUp
  case pageDown
  case pushToTalk
  case shortcut1
  case shortcut2
  case shortcut3

  var id: String { rawValue }

  var title: String {
    switch self {
    case .none: return "无操作"
    case .primaryClick: return "左键"
    case .secondaryClick: return "右键"
    case .pageUp: return "向上翻页"
    case .pageDown: return "向下翻页"
    case .pushToTalk: return "按住说话"
    case .shortcut1: return "快捷键 1"
    case .shortcut2: return "快捷键 2"
    case .shortcut3: return "快捷键 3"
    }
  }

  var systemImage: String {
    switch self {
    case .none: return "minus.circle"
    case .primaryClick: return "cursorarrow.click"
    case .secondaryClick: return "contextualmenu.and.cursorarrow"
    case .pageUp: return "arrow.up.to.line"
    case .pageDown: return "arrow.down.to.line"
    case .pushToTalk: return "mic.fill"
    case .shortcut1, .shortcut2, .shortcut3: return "keyboard"
    }
  }
}

struct ControllerMapping: Codable, Equatable {
  var cross: ControllerAction
  var circle: ControllerAction
  var create: ControllerAction
  var dpadUp: ControllerAction
  var dpadDown: ControllerAction
  var microphone: ControllerAction

  static let standard = ControllerMapping(
    cross: .primaryClick,
    circle: .secondaryClick,
    create: .none,
    dpadUp: .pageUp,
    dpadDown: .pageDown,
    microphone: .pushToTalk
  )
}

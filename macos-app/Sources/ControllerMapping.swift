import Foundation

enum ControllerAction: String, CaseIterable, Codable, Identifiable {
  case none
  case primaryClick
  case secondaryClick
  case pageUp
  case pageDown
  case pushToTalk

  var id: String { rawValue }

  var title: String {
    switch self {
    case .none: return "无操作"
    case .primaryClick: return "左键"
    case .secondaryClick: return "右键"
    case .pageUp: return "向上翻页"
    case .pageDown: return "向下翻页"
    case .pushToTalk: return "按住说话"
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

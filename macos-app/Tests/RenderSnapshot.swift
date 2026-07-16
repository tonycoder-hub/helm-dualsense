import AppKit
import SwiftUI

@main
struct RenderSnapshot {
  @MainActor
  static func main() throws {
    guard CommandLine.arguments.count == 2 else {
      throw SnapshotError.usage
    }
    let model = AppModel()
    model.statusMessage = "界面预览：启动默认停用，等待连接 DualSense。"
    let root = ControlCenterView()
      .environmentObject(model)
      .frame(width: 780, height: 980)
    let hostingView = NSHostingView(rootView: root)
    hostingView.frame = NSRect(x: 0, y: 0, width: 780, height: 980)
    hostingView.layoutSubtreeIfNeeded()

    guard let representation = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
    else {
      throw SnapshotError.renderFailed
    }
    hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
    guard let png = representation.representation(using: .png, properties: [:]) else {
      throw SnapshotError.renderFailed
    }
    try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
    print("UI_SNAPSHOT=PASS")
  }
}

enum SnapshotError: LocalizedError {
  case usage
  case renderFailed

  var errorDescription: String? {
    switch self {
    case .usage: return "usage: RenderSnapshot <output.png>"
    case .renderFailed: return "could not render SwiftUI snapshot"
    }
  }
}

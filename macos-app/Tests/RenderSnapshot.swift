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
    model.audioDevices = [
      AudioInputDevice(
        id: 1,
        name: "MacBook Pro 麦克风",
        isDefault: false,
        transport: .builtIn
      ),
      AudioInputDevice(
        id: 2,
        name: "AirPods 麦克风",
        isDefault: true,
        transport: .bluetooth
      ),
    ]
    model.selectedAudioDeviceID = 1
    model.leftTriggerValue = 0.35
    model.rightTriggerValue = 0.55
    let root = ControlCenterView()
      .environmentObject(model)
      .frame(width: 780, height: 1_500)
    let hostingView = NSHostingView(rootView: root)
    hostingView.frame = NSRect(x: 0, y: 0, width: 780, height: 1_500)
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

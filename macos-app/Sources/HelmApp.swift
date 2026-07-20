import AppKit
import SwiftUI

final class HelmApplicationDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }
}

@main
struct HelmDemoApp: App {
  @NSApplicationDelegateAdaptor(HelmApplicationDelegate.self) private var appDelegate
  @StateObject private var model = AppModel()

  var body: some Scene {
    Window("GripPilot · 手柄控制中心", id: "control-center") {
      ControlCenterView()
        .environmentObject(model)
        .frame(minWidth: 720, idealWidth: 780, minHeight: 650, idealHeight: 760)
        .onAppear { model.start() }
    }
    .defaultSize(width: 780, height: 760)
    .windowStyle(.hiddenTitleBar)

    MenuBarExtra {
      MenuBarPanel()
        .environmentObject(model)
        .onAppear { model.start() }
    } label: {
      Image(systemName: model.isListening ? "waveform.circle.fill" : model.controllerSystemImage)
    }
    .menuBarExtraStyle(.window)
  }
}

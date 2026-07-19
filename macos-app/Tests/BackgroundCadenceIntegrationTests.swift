import AppKit
import Foundation

@MainActor
@main
struct BackgroundCadenceIntegrationTests {
  static func main() {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    guard !application.isActive else {
      fail("cadence fixture unexpectedly became the active application")
    }

    let activity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
      reason: "Helm inactive 240 Hz cadence integration test"
    )
    defer { ProcessInfo.processInfo.endActivity(activity) }

    let driver = InputCadenceDriver()
    let counterLock = NSLock()
    var ticks = 0
    var observedMainThreadCallback = false
    _ = driver.start(rate: 60) {
      counterLock.lock()
      ticks += 1
      observedMainThreadCallback = observedMainThreadCallback || Thread.isMainThread
      counterLock.unlock()
    }

    // This reproduces the production failure boundary: SwiftUI/AppKit can keep
    // the main thread busy, but analog sampling must remain independent.
    let duration = 0.75
    let startedAt = ProcessInfo.processInfo.systemUptime
    while ProcessInfo.processInfo.systemUptime - startedAt < duration {
      _ = ProcessInfo.processInfo.systemUptime
    }
    let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
    driver.stop()

    counterLock.lock()
    let measuredTicks = ticks
    let callbackUsedMainThread = observedMainThreadCallback
    counterLock.unlock()
    let measuredRate = Double(ticks) / elapsed
    guard measuredRate >= 220 else {
      fail(
        "main-thread isolation cadence fell below 220 Hz "
          + "ticks=\(measuredTicks) elapsed=\(elapsed) rate=\(measuredRate)"
      )
    }
    guard !callbackUsedMainThread else {
      fail("analog cadence callback ran on the blocked main thread")
    }
    print(
      "BACKGROUND_CADENCE_INTEGRATION_TESTS=PASS active=\(application.isActive) "
        + "requested=60 locked=240 measured=\(Int(measuredRate.rounded())) mainIsolated=true"
    )
  }

  private static func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

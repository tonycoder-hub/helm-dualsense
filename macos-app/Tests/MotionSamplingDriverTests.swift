import CoreGraphics
import Foundation

@main
struct MotionSamplingDriverTests {
  static func main() {
    let outputLock = NSLock()
    let blockedOutputEntered = DispatchSemaphore(value: 0)
    let allowBlockedOutputToFinish = DispatchSemaphore(value: 0)
    var pointerOutputs = 0
    var outputRanOnMainThread = false
    var shouldBlockNextOutput = false

    let driver = MotionSamplingDriver(
      analogReader: {
        ControllerAnalogSample(
          leftX: 0.82,
          leftY: 0,
          rightY: 0,
          leftTrigger: 0,
          rightTrigger: 0
        )
      },
      pointerOutput: { _, _, _ in
        outputLock.lock()
        pointerOutputs += 1
        outputRanOnMainThread = outputRanOnMainThread || Thread.isMainThread
        let shouldBlock = shouldBlockNextOutput
        shouldBlockNextOutput = false
        outputLock.unlock()
        if shouldBlock {
          blockedOutputEntered.signal()
          _ = allowBlockedOutputToFinish.wait(timeout: .now() + 1)
        }
        return true
      },
      scrollOutput: { _ in true }
    )
    driver.updateConfiguration(
      MotionSamplingConfiguration(outputEnabled: true)
    )

    _ = driver.start(rate: 60)
    let duration = 1.25
    let startedAt = ProcessInfo.processInfo.systemUptime
    while ProcessInfo.processInfo.systemUptime - startedAt < duration {
      _ = ProcessInfo.processInfo.systemUptime
    }
    let elapsed = ProcessInfo.processInfo.systemUptime - startedAt

    outputLock.lock()
    let measuredOutputs = pointerOutputs
    let usedMainThread = outputRanOnMainThread
    outputLock.unlock()
    let outputRate = Double(measuredOutputs) / elapsed
    let telemetry = driver.latestTelemetry()

    guard outputRate >= 220 else {
      fail(
        "main-thread isolation output fell below 220 Hz "
          + "outputs=\(measuredOutputs) elapsed=\(elapsed) rate=\(outputRate)"
      )
    }
    guard telemetry.inputRate >= 220, telemetry.outputRate >= 220 else {
      fail(
        "driver telemetry did not report the real isolated cadence "
          + "input=\(telemetry.inputRate) output=\(telemetry.outputRate)"
      )
    }
    guard !usedMainThread else {
      fail("motion output callback ran on the blocked main thread")
    }

    outputLock.lock()
    shouldBlockNextOutput = true
    outputLock.unlock()
    guard blockedOutputEntered.wait(timeout: .now() + 0.25) == .success else {
      fail("could not stage an in-flight motion output for the drain barrier")
    }
    let barrierReturned = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      driver.disableOutputAndWait()
      barrierReturned.signal()
    }
    guard barrierReturned.wait(timeout: .now() + 0.05) == .timedOut else {
      fail("disable barrier returned before an in-flight output completed")
    }
    allowBlockedOutputToFinish.signal()
    guard barrierReturned.wait(timeout: .now() + 0.5) == .success else {
      fail("disable barrier did not drain after the in-flight output completed")
    }
    outputLock.lock()
    let outputsAfterBarrier = pointerOutputs
    outputLock.unlock()
    Thread.sleep(forTimeInterval: 0.1)
    outputLock.lock()
    let outputsAfterDisabledWait = pointerOutputs
    outputLock.unlock()
    guard outputsAfterDisabledWait == outputsAfterBarrier else {
      fail("motion output continued after the synchronous disable barrier")
    }

    driver.updateConfiguration(MotionSamplingConfiguration(outputEnabled: true))
    Thread.sleep(forTimeInterval: 0.1)
    outputLock.lock()
    let outputsAfterReenable = pointerOutputs
    outputLock.unlock()
    guard outputsAfterReenable > outputsAfterDisabledWait else {
      fail("motion output did not recover after a disable barrier and re-enable")
    }
    driver.stop()

    let gapLock = NSLock()
    var shouldCreateLongGap = true
    var gapDriverOutputs = 0
    let gapDriver = MotionSamplingDriver(
      analogReader: {
        gapLock.lock()
        let shouldBlock = shouldCreateLongGap
        shouldCreateLongGap = false
        gapLock.unlock()
        if shouldBlock { Thread.sleep(forTimeInterval: 2.05) }
        return ControllerAnalogSample(
          leftX: 0.82,
          leftY: 0,
          rightY: 0,
          leftTrigger: 0,
          rightTrigger: 0
        )
      },
      pointerOutput: { _, _, _ in
        gapLock.lock()
        gapDriverOutputs += 1
        gapLock.unlock()
        return true
      },
      scrollOutput: { _ in true }
    )
    gapDriver.updateConfiguration(MotionSamplingConfiguration(outputEnabled: true))
    _ = gapDriver.start(rate: 240)
    Thread.sleep(forTimeInterval: 2.25)
    guard gapDriver.latestTelemetry().emergencyStopRequested else {
      fail("long cadence gap did not latch the emergency-stop request")
    }
    gapDriver.disableOutputAndWait()
    guard !gapDriver.latestTelemetry().emergencyStopRequested else {
      fail("synchronous disable barrier did not acknowledge the emergency-stop request")
    }
    gapLock.lock()
    let outputsBeforeGapRecovery = gapDriverOutputs
    gapLock.unlock()
    gapDriver.updateConfiguration(MotionSamplingConfiguration(outputEnabled: true))
    Thread.sleep(forTimeInterval: 0.12)
    gapLock.lock()
    let outputsAfterGapRecovery = gapDriverOutputs
    gapLock.unlock()
    gapDriver.stop()
    guard outputsAfterGapRecovery > outputsBeforeGapRecovery else {
      fail("motion output stayed latched off after acknowledging a long-gap emergency")
    }
    print(
      "MOTION_SAMPLING_DRIVER_TESTS=PASS "
        + "input=\(Int(telemetry.inputRate.rounded())) "
        + "output=\(Int(outputRate.rounded())) mainIsolated=true "
        + "drainBarrier=true emergencyRecovery=true"
    )
  }

  private static func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

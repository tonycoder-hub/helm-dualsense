import Foundation

@main
struct InputCadenceTests {
  @MainActor
  static func main() {
    let driver = InputCadenceDriver()

    func measure(rate: Double, duration: TimeInterval) -> Int {
      var ticks = 0
      _ = driver.start(rate: rate) { ticks += 1 }
      RunLoop.main.run(until: Date().addingTimeInterval(duration))
      driver.stop()
      return ticks
    }

    let highRateTicks = measure(rate: 240, duration: 0.5)
    let lowRateTicks = measure(rate: 60, duration: 0.5)
    guard highRateTicks >= 80, highRateTicks > lowRateTicks * 2 else {
      fputs(
        "FAIL: active cadence did not distinguish 240 Hz from 60 Hz "
          + "(high=\(highRateTicks), low=\(lowRateTicks))\n",
        stderr
      )
      exit(1)
    }
    print("INPUT_CADENCE_TESTS=PASS high=\(highRateTicks) low=\(lowRateTicks)")
  }
}

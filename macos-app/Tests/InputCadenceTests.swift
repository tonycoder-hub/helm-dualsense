import Foundation

@main
struct InputCadenceTests {
  @MainActor
  static func main() {
    let driver = InputCadenceDriver()

    func measure(rate: Double, duration: TimeInterval) -> Int {
      let lock = NSLock()
      var ticks = 0
      _ = driver.start(rate: rate) {
        lock.lock()
        ticks += 1
        lock.unlock()
      }
      RunLoop.main.run(until: Date().addingTimeInterval(duration))
      driver.stop()
      lock.lock()
      let measuredTicks = ticks
      lock.unlock()
      return measuredTicks
    }

    let explicit240Ticks = measure(rate: 240, duration: 0.5)
    let attempted60Ticks = measure(rate: 60, duration: 0.5)
    let allowedDifference = max(Int(Double(explicit240Ticks) * 0.15), 8)
    guard explicit240Ticks >= 90, attempted60Ticks >= 90,
      abs(explicit240Ticks - attempted60Ticks) <= allowedDifference
    else {
      fputs(
        "FAIL: input cadence was not locked to 240 Hz "
          + "(explicit=\(explicit240Ticks), attempted60=\(attempted60Ticks))\n",
        stderr
      )
      exit(1)
    }
    print(
      "INPUT_CADENCE_TESTS=PASS locked=240 explicit=\(explicit240Ticks) attempted60=\(attempted60Ticks)"
    )
  }
}

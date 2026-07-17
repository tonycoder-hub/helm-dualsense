import Foundation

@MainActor
final class InputCadenceDriver {
  private var timer: DispatchSourceTimer?
  private var callback: (() -> Void)?

  deinit {
    timer?.setEventHandler {}
    timer?.cancel()
  }

  @discardableResult
  func start(rate: Double, _ callback: @escaping () -> Void) -> String {
    stop()
    self.callback = callback
    let clampedRate = InputCadencePolicy.clampedRate(rate)
    let interval = InputCadencePolicy.interval(for: clampedRate)
    let intervalNanoseconds = Int((interval * 1_000_000_000).rounded())
    let leewayNanoseconds = min(
      Int((interval * 0.04 * 1_000_000_000).rounded()),
      250_000
    )
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(
      deadline: .now() + .nanoseconds(intervalNanoseconds),
      repeating: .nanoseconds(intervalNanoseconds),
      leeway: .nanoseconds(leewayNanoseconds)
    )
    timer.setEventHandler { [weak self] in
      MainActor.assumeIsolated {
        self?.callback?()
      }
    }
    self.timer = timer
    timer.resume()
    return "\(Int(clampedRate)) Hz 主动采样"
  }

  func stop() {
    timer?.setEventHandler {}
    timer?.cancel()
    timer = nil
    callback = nil
  }
}

import Foundation

final class InputCadenceDriver {
  private let queueKey = DispatchSpecificKey<UInt8>()
  private let queue = DispatchQueue(
    label: "io.github.tonycoder-hub.helm.analog-cadence",
    qos: .userInteractive
  )
  private var timer: DispatchSourceTimer?
  private var callback: (() -> Void)?

  init() {
    queue.setSpecific(key: queueKey, value: 1)
  }

  deinit {
    timer?.setEventHandler {}
    timer?.cancel()
  }

  @discardableResult
  func start(rate: Double, _ callback: @escaping () -> Void) -> String {
    let clampedRate = InputCadencePolicy.clampedRate(rate)
    let interval = InputCadencePolicy.interval(for: clampedRate)
    let intervalNanoseconds = Int((interval * 1_000_000_000).rounded())
    performSynchronously {
      stopLocked()
      self.callback = callback
      let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
      timer.schedule(
        deadline: .now() + .nanoseconds(intervalNanoseconds),
        repeating: .nanoseconds(intervalNanoseconds),
        leeway: .nanoseconds(0)
      )
      timer.setEventHandler { [weak self] in
        self?.callback?()
      }
      self.timer = timer
      timer.resume()
    }
    return "\(Int(clampedRate)) Hz 独立高优先级采样"
  }

  func stop() {
    performSynchronously { stopLocked() }
  }

  func performSynchronously(_ operation: () -> Void) {
    if DispatchQueue.getSpecific(key: queueKey) == 1 {
      operation()
    } else {
      queue.sync(execute: operation)
    }
  }

  private func stopLocked() {
    timer?.setEventHandler {}
    timer?.cancel()
    timer = nil
    callback = nil
  }
}

@MainActor
final class MainEventCadenceDriver {
  private var timer: DispatchSourceTimer?
  private var callback: (() -> Void)?

  deinit {
    timer?.setEventHandler {}
    timer?.cancel()
  }

  @discardableResult
  func start(rate: Double = 60, _ callback: @escaping () -> Void) -> String {
    stop()
    self.callback = callback
    let safeRate = min(max(rate, 30), 120)
    let intervalNanoseconds = Int((1_000_000_000 / safeRate).rounded())
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(
      deadline: .now() + .nanoseconds(intervalNanoseconds),
      repeating: .nanoseconds(intervalNanoseconds),
      leeway: .milliseconds(1)
    )
    timer.setEventHandler { [weak self] in
      MainActor.assumeIsolated {
        self?.callback?()
      }
    }
    self.timer = timer
    timer.resume()
    return "\(Int(safeRate)) Hz 主线程离散事件泵"
  }

  func stop() {
    timer?.setEventHandler {}
    timer?.cancel()
    timer = nil
    callback = nil
  }
}

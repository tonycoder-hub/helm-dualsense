import CoreGraphics
import Foundation

struct MotionSamplingConfiguration: Equatable {
  var outputEnabled: Bool
  var leftButtonDown = false
  var rightButtonDown = false
  var pointerGain = 1.0
  var scrollGain = 8.0
  var responseExponent = ControlMath.defaultStickResponseExponent
  var responseTime = ControlMath.defaultStickSmoothingTime
  var accelerationDuration = 1.6
  var maximumBoost = 2.2
  var brakeMinimumSpeed = 0.28
  var acceleratorMaximumSpeed = 2.6
}

struct MotionSamplingTelemetry: Equatable {
  let inputRate: Double
  let outputRate: Double
  let jitterP95Milliseconds: Double
  let jitterMaximumMilliseconds: Double
  let lateTickPercentage: Double
  let analogState: ControllerAnalogState
  let emergencyStopRequested: Bool

  static let zero = MotionSamplingTelemetry(
    inputRate: 0,
    outputRate: 0,
    jitterP95Milliseconds: 0,
    jitterMaximumMilliseconds: 0,
    lateTickPercentage: 0,
    analogState: ControllerAnalogState(),
    emergencyStopRequested: false
  )
}

final class MotionSamplingDriver {
  typealias AnalogReader = () -> ControllerAnalogSample?
  typealias PointerOutput = (CGPoint, Bool, Bool) -> Bool
  typealias ScrollOutput = (ContinuousScrollSample) -> Bool

  private let cadenceDriver = InputCadenceDriver()
  private let analogReader: AnalogReader
  private let pointerOutput: PointerOutput
  private let scrollOutput: ScrollOutput

  private let configurationLock = NSLock()
  private var configuration = MotionSamplingConfiguration(outputEnabled: false)
  private var requestedResetGeneration: UInt64 = 0
  private var appliedResetGeneration: UInt64 = 0

  private let telemetryLock = NSLock()
  private var latestTelemetrySnapshot = MotionSamplingTelemetry.zero
  private let telemetryDeliveryLock = NSLock()
  private var telemetryDeliveryQueue = DispatchQueue.main
  private var telemetryHandler: ((MotionSamplingTelemetry) -> Void)?
  private var pendingTelemetry: MotionSamplingTelemetry?
  private var telemetryDeliveryScheduled = false

  // The following state is exclusively owned by InputCadenceDriver's serial queue.
  private var analogState = ControllerAnalogState()
  private var pointerFilter = StickMotionFilter()
  private var scrollFilter = StickMotionFilter()
  private var scrollAccumulator = ContinuousScrollAccumulator()
  private var leftStickActiveSince: TimeInterval?
  private var scrollOutputActive = false
  private var outputWasEnabled = false
  private var lastTick = 0.0
  private var cadenceMeasurementStartedAt = 0.0
  private var cadenceTickCount = 0
  private var outputTickCount = 0
  private var measuredInputRate = 0.0
  private var measuredOutputRate = 0.0
  private var jitterWindowStartedAt = 0.0
  private var gapSamples: [TimeInterval] = []
  private var jitterP95Milliseconds = 0.0
  private var jitterMaximumMilliseconds = 0.0
  private var lateTickPercentage = 0.0
  private var nextTelemetryAt = 0.0
  private var emergencyStopRequested = false

  init(
    analogReader: @escaping AnalogReader,
    pointerOutput: @escaping PointerOutput,
    scrollOutput: @escaping ScrollOutput
  ) {
    self.analogReader = analogReader
    self.pointerOutput = pointerOutput
    self.scrollOutput = scrollOutput
  }

  @discardableResult
  func start(rate: Double) -> String {
    cadenceDriver.stop()
    prepareForStart()
    return cadenceDriver.start(rate: rate) { [weak self] in
      self?.tick()
    }
  }

  func stop() {
    cadenceDriver.stop()
    resetMotionIntegrationState()
  }

  func updateConfiguration(_ configuration: MotionSamplingConfiguration) {
    configurationLock.lock()
    self.configuration = configuration
    configurationLock.unlock()
  }

  func disableOutputAndWait() {
    configurationLock.lock()
    configuration.outputEnabled = false
    requestedResetGeneration &+= 1
    let resetGeneration = requestedResetGeneration
    configurationLock.unlock()

    cadenceDriver.performSynchronously {
      appliedResetGeneration = resetGeneration
      emergencyStopRequested = false
      resetMotionIntegrationState()
      publishCurrentTelemetry()
    }
  }

  func requestMotionReset() {
    configurationLock.lock()
    requestedResetGeneration &+= 1
    configurationLock.unlock()
  }

  func setTelemetryHandler(
    queue: DispatchQueue = .main,
    _ handler: @escaping (MotionSamplingTelemetry) -> Void
  ) {
    telemetryDeliveryLock.lock()
    telemetryDeliveryQueue = queue
    telemetryHandler = handler
    telemetryDeliveryLock.unlock()
  }

  func latestTelemetry() -> MotionSamplingTelemetry {
    telemetryLock.lock()
    let telemetry = latestTelemetrySnapshot
    telemetryLock.unlock()
    return telemetry
  }

  private func prepareForStart() {
    resetMotionIntegrationState()
    lastTick = 0
    cadenceMeasurementStartedAt = 0
    cadenceTickCount = 0
    outputTickCount = 0
    measuredInputRate = 0
    measuredOutputRate = 0
    jitterWindowStartedAt = 0
    gapSamples.removeAll(keepingCapacity: true)
    jitterP95Milliseconds = 0
    jitterMaximumMilliseconds = 0
    lateTickPercentage = 0
    nextTelemetryAt = 0
    emergencyStopRequested = false
    storeTelemetry(.zero)
  }

  private func tick() {
    let now = ProcessInfo.processInfo.systemUptime
    let interval = InputCadencePolicy.interval(for: InputCadencePolicy.fixedRate)
    let elapsed = lastTick == 0 ? interval : now - lastTick
    lastTick = now

    configurationLock.lock()
    let currentConfiguration = configuration
    let resetGeneration = requestedResetGeneration
    configurationLock.unlock()
    if appliedResetGeneration != resetGeneration {
      appliedResetGeneration = resetGeneration
      resetMotionIntegrationState()
    }

    cadenceTickCount += 1
    if cadenceMeasurementStartedAt == 0 {
      cadenceMeasurementStartedAt = now
      jitterWindowStartedAt = now
    }
    if elapsed > 0, elapsed < ControlMath.maximumTimerGap {
      gapSamples.append(elapsed)
    }
    if TimerGapPolicy.shouldEmergencyStop(
      elapsed: elapsed,
      hasActiveInput: currentConfiguration.outputEnabled
    ) {
      emergencyStopRequested = true
      resetMotionIntegrationState()
    }

    let sample = analogReader()
    if let sample {
      analogState.applyPolledSample(sample)
    } else {
      analogState.reset()
      resetMotionIntegrationState()
    }

    if currentConfiguration.outputEnabled, sample != nil, !emergencyStopRequested {
      outputWasEnabled = true
      produceMotionOutput(configuration: currentConfiguration, now: now, elapsed: elapsed)
    } else if outputWasEnabled {
      resetMotionIntegrationState()
    }

    updateMeasurements(now: now)
    if now >= nextTelemetryAt {
      publishCurrentTelemetry()
      nextTelemetryAt = now + 1.0 / 15.0
    }
  }

  private func produceMotionOutput(
    configuration: MotionSamplingConfiguration,
    now: TimeInterval,
    elapsed: TimeInterval
  ) {
    let safeElapsed = TimerGapPolicy.integrationDeltaTime(elapsed: elapsed)
    let speedMultiplier = ControlMath.racingSpeedMultiplier(
      brake: analogState.leftTrigger,
      accelerator: analogState.rightTrigger,
      minimumSpeed: configuration.brakeMinimumSpeed,
      maximumSpeed: configuration.acceleratorMaximumSpeed
    )
    let pointerVector = pointerFilter.update(
      x: analogState.leftX,
      y: analogState.leftY,
      deadZone: ControlMath.stickDeadZone,
      responseExponent: configuration.responseExponent,
      responseTime: configuration.responseTime,
      deltaTime: safeElapsed
    )
    if hypot(pointerVector.x, pointerVector.y) > 0 {
      if leftStickActiveSince == nil { leftStickActiveSince = now }
    } else {
      leftStickActiveSince = nil
    }
    let holdDuration = leftStickActiveSince.map { max(now - $0, 0) } ?? 0
    let pointer = ControlMath.integratedStickPointerDelta(
      x: pointerVector.x,
      y: pointerVector.y,
      gain: configuration.pointerGain * speedMultiplier,
      maximumSpeed: ControlMath.stickPointerMaximumSpeed,
      holdDuration: holdDuration,
      accelerationDuration: configuration.accelerationDuration,
      maximumBoost: configuration.maximumBoost,
      deltaTime: safeElapsed
    )

    let scrollVector = scrollFilter.update(
      x: 0,
      y: analogState.rightY,
      deadZone: ControlMath.scrollStickDeadZone,
      responseExponent: configuration.responseExponent,
      responseTime: configuration.responseTime,
      deltaTime: safeElapsed
    )
    let scrollPixels = ControlMath.continuousScrollDelta(
      axis: scrollVector.y,
      deadZone: 0,
      gain: configuration.scrollGain * speedMultiplier,
      deltaTime: safeElapsed
    )
    let scrollWasActive = scrollOutputActive
    scrollOutputActive = scrollPixels != 0

    var producedOutput = false
    if pointer != .zero {
      let pointerWasPosted = pointerOutput(
        pointer,
        configuration.leftButtonDown,
        configuration.rightButtonDown
      )
      producedOutput = producedOutput || pointerWasPosted
    }
    if scrollOutputActive || scrollWasActive {
      let scrollSample = scrollAccumulator.update(precisePixels: scrollPixels)
      if scrollSample != .zero {
        let scrollWasPosted = scrollOutput(scrollSample)
        producedOutput = producedOutput || scrollWasPosted
      }
      if scrollWasActive, !scrollOutputActive {
        scrollAccumulator.reset()
      }
    }
    if producedOutput { outputTickCount += 1 }
  }

  private func updateMeasurements(now: TimeInterval) {
    let measurementElapsed = now - cadenceMeasurementStartedAt
    if measurementElapsed >= 1 {
      measuredInputRate = Double(cadenceTickCount) / measurementElapsed
      measuredOutputRate = Double(outputTickCount) / measurementElapsed
      cadenceMeasurementStartedAt = now
      cadenceTickCount = 0
      outputTickCount = 0
    }

    guard now - jitterWindowStartedAt >= 5, !gapSamples.isEmpty else { return }
    let ordered = gapSamples.sorted()
    jitterP95Milliseconds = percentile(ordered, fraction: 0.95) * 1_000
    jitterMaximumMilliseconds = (ordered.last ?? 0) * 1_000
    let expected = InputCadencePolicy.interval(for: InputCadencePolicy.fixedRate)
    lateTickPercentage = 100 * Double(ordered.filter { $0 > expected * 1.5 }.count)
      / Double(ordered.count)
    jitterWindowStartedAt = now
    gapSamples.removeAll(keepingCapacity: true)
  }

  private func publishCurrentTelemetry() {
    let telemetry = MotionSamplingTelemetry(
      inputRate: measuredInputRate,
      outputRate: measuredOutputRate,
      jitterP95Milliseconds: jitterP95Milliseconds,
      jitterMaximumMilliseconds: jitterMaximumMilliseconds,
      lateTickPercentage: lateTickPercentage,
      analogState: analogState,
      emergencyStopRequested: emergencyStopRequested
    )
    storeTelemetry(telemetry)

    telemetryDeliveryLock.lock()
    pendingTelemetry = telemetry
    let shouldSchedule = telemetryHandler != nil && !telemetryDeliveryScheduled
    if shouldSchedule { telemetryDeliveryScheduled = true }
    let queue = telemetryDeliveryQueue
    telemetryDeliveryLock.unlock()
    guard shouldSchedule else { return }
    queue.async { [weak self] in
      self?.deliverPendingTelemetry()
    }
  }

  private func storeTelemetry(_ telemetry: MotionSamplingTelemetry) {
    telemetryLock.lock()
    latestTelemetrySnapshot = telemetry
    telemetryLock.unlock()
  }

  private func deliverPendingTelemetry() {
    telemetryDeliveryLock.lock()
    let telemetry = pendingTelemetry
    pendingTelemetry = nil
    telemetryDeliveryScheduled = false
    let handler = telemetryHandler
    telemetryDeliveryLock.unlock()
    if let telemetry { handler?(telemetry) }
  }

  private func resetMotionIntegrationState() {
    pointerFilter.reset()
    scrollFilter.reset()
    scrollAccumulator.reset()
    leftStickActiveSince = nil
    scrollOutputActive = false
    outputWasEnabled = false
  }

  private func percentile(
    _ orderedValues: [TimeInterval],
    fraction: Double
  ) -> TimeInterval {
    guard !orderedValues.isEmpty else { return 0 }
    let index = min(
      max(Int((Double(orderedValues.count - 1) * fraction).rounded()), 0),
      orderedValues.count - 1
    )
    return orderedValues[index]
  }
}

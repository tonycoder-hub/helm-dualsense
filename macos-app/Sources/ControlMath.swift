import CoreGraphics
import Foundation

struct StickMotionFilter {
  private static let minimumOutputMagnitude = 0.12
  private static let minimumOutputRampWidth = 0.08
  private var filtered = CGPoint.zero

  mutating func update(
    x: Double,
    y: Double,
    deadZone: Double,
    responseExponent: Double,
    responseTime: TimeInterval,
    deltaTime: TimeInterval
  ) -> CGPoint {
    let rawMagnitude = hypot(x, y)
    guard rawMagnitude > deadZone, deadZone < 1 else {
      filtered = .zero
      return .zero
    }

    let magnitude = min(rawMagnitude, 1)
    let normalizedMagnitude = min(max((magnitude - deadZone) / (1 - deadZone), 0), 1)
    let curveMagnitude = pow(normalizedMagnitude, max(responseExponent, 0.1))
    let rampProgress = min(
      normalizedMagnitude / Self.minimumOutputRampWidth,
      1
    )
    let smoothRamp = rampProgress * rampProgress * (3 - 2 * rampProgress)
    let minimumResponse = Self.minimumOutputMagnitude * smoothRamp
    let shapedMagnitude = minimumResponse + (1 - minimumResponse) * curveMagnitude
    let target = CGPoint(
      x: x / rawMagnitude * shapedMagnitude,
      y: y / rawMagnitude * shapedMagnitude
    )
    let elapsed = max(deltaTime, 0)
    let timeConstant = max(responseTime, 0.000_1)
    let retained = exp(-elapsed / timeConstant)
    filtered = CGPoint(
      x: target.x + (filtered.x - target.x) * retained,
      y: target.y + (filtered.y - target.y) * retained
    )
    return filtered
  }

  mutating func reset() {
    filtered = .zero
  }
}

enum TimerGapPolicy {
  static let emergencyThreshold: TimeInterval = 2.0

  static func shouldEmergencyStop(
    elapsed: TimeInterval,
    hasActiveInput: Bool
  ) -> Bool {
    hasActiveInput && elapsed > emergencyThreshold
  }

  static func integrationDeltaTime(elapsed: TimeInterval) -> TimeInterval {
    let safeElapsed = max(elapsed, 0)
    return safeElapsed > ControlMath.maximumTimerGap ? 0 : safeElapsed
  }
}

enum InputCadencePolicy {
  static let minimumRate = 60.0
  static let maximumRate = 240.0
  static let defaultRate = 240.0
  static let selectableRates = [60.0, 90.0, 120.0, 144.0, 240.0]

  static func clampedRate(_ rate: Double) -> Double {
    min(max(rate, minimumRate), maximumRate)
  }

  static func interval(for rate: Double) -> TimeInterval {
    1.0 / clampedRate(rate)
  }
}

enum ControlMath {
  static let maximumTimerGap: TimeInterval = 0.250
  static let safetyChordWindow: TimeInterval = 2.0
  static let stickDeadZone = 0.16
  static let scrollStickDeadZone = 0.12
  static let defaultStickResponseExponent = 1.05
  static let defaultStickSmoothingTime: TimeInterval = 0.006
  static let stickPointerMaximumSpeed = 1_100.0
  static let stickPointerAbsoluteMaximumSpeed = 4_800.0
  static let stickAccelerationDelay = 0.25

  static func safetyChordIsValid(
    modifierPressedAt: TimeInterval?,
    buttonPressedAt: TimeInterval
  ) -> Bool {
    guard let modifierPressedAt else { return false }
    let elapsed = buttonPressedAt - modifierPressedAt
    return elapsed >= 0 && elapsed <= safetyChordWindow
  }

  static func scrollDelta(
    axis: Double,
    deadZone: Double,
    gain: Double,
    deltaTime: TimeInterval,
    remainder: inout Double
  ) -> Int32 {
    let magnitude = abs(axis)
    guard magnitude > deadZone else {
      remainder = 0
      return 0
    }
    let normalized = (magnitude - deadZone) / (1 - deadZone) * (axis < 0 ? -1 : 1)
    remainder += -normalized * gain * (deltaTime / (1.0 / 60.0))
    let whole = Int32(remainder.rounded(.towardZero))
    remainder -= Double(whole)
    return whole
  }

  static func continuousScrollDelta(
    axis: Double,
    deadZone: Double,
    gain: Double,
    deltaTime: TimeInterval
  ) -> Double {
    let magnitude = abs(axis)
    guard magnitude > deadZone, deadZone < 1 else { return 0 }
    let normalized = (magnitude - deadZone) / (1 - deadZone) * (axis < 0 ? -1 : 1)
    return -normalized * gain * (max(deltaTime, 0) / (1.0 / 60.0))
  }

  static func pointerDelta(
    from previous: CGPoint,
    to current: CGPoint,
    elapsed: TimeInterval,
    surfaceSize: CGSize,
    gain: Double,
    acceleration: Double,
    maximum: Double
  ) -> CGPoint {
    let rawX = (current.x - previous.x) * surfaceSize.width
    let rawY = (current.y - previous.y) * surfaceSize.height
    let safeElapsed = max(elapsed, 0.001)
    let velocity = hypot(rawX, rawY) / (safeElapsed * 1_000)
    let multiplier = gain * (1 + acceleration * min(velocity / 2.5, 3))
    var dx = rawX * multiplier
    var dy = rawY * multiplier
    let magnitude = hypot(dx, dy)
    if magnitude > maximum {
      let scale = maximum / magnitude
      dx *= scale
      dy *= scale
    }
    return CGPoint(x: dx, y: dy)
  }

  static func stickPointerDelta(
    x: Double,
    y: Double,
    deadZone: Double,
    gain: Double,
    maximumSpeed: Double,
    holdDuration: TimeInterval,
    accelerationDuration: TimeInterval,
    maximumBoost: Double,
    deltaTime: TimeInterval
  ) -> CGPoint {
    let rawMagnitude = hypot(x, y)
    guard rawMagnitude > deadZone, deadZone < 1 else { return .zero }

    let magnitude = min(rawMagnitude, 1)
    let normalizedMagnitude = (magnitude - deadZone) / (1 - deadZone)
    let shapedMagnitude = pow(normalizedMagnitude, 1.65)
    return integratedStickPointerDelta(
      x: x / rawMagnitude * shapedMagnitude,
      y: y / rawMagnitude * shapedMagnitude,
      gain: gain,
      maximumSpeed: maximumSpeed,
      holdDuration: holdDuration,
      accelerationDuration: accelerationDuration,
      maximumBoost: maximumBoost,
      deltaTime: deltaTime
    )
  }

  static func integratedStickPointerDelta(
    x: Double,
    y: Double,
    gain: Double,
    maximumSpeed: Double,
    holdDuration: TimeInterval,
    accelerationDuration: TimeInterval,
    maximumBoost: Double,
    deltaTime: TimeInterval
  ) -> CGPoint {
    let magnitude = min(hypot(x, y), 1)
    guard magnitude > 0 else { return .zero }
    let elapsed = min(max(deltaTime, 0), maximumTimerGap)
    let boost = stickHoldBoost(
      holdDuration: holdDuration,
      delay: stickAccelerationDelay,
      accelerationDuration: accelerationDuration,
      maximumBoost: maximumBoost
    )
    let effectiveSpeed = min(
      maximumSpeed * max(gain, 0) * boost,
      stickPointerAbsoluteMaximumSpeed
    )
    let distance = effectiveSpeed * magnitude * elapsed
    return CGPoint(
      x: x / magnitude * distance,
      y: y / magnitude * distance
    )
  }

  static func stickHoldBoost(
    holdDuration: TimeInterval,
    delay: TimeInterval,
    accelerationDuration: TimeInterval,
    maximumBoost: Double
  ) -> Double {
    let safeMaximum = max(maximumBoost, 1)
    guard holdDuration > delay else { return 1 }
    let duration = max(accelerationDuration, 0.001)
    let progress = min(max((holdDuration - delay) / duration, 0), 1)
    let smoothstep = progress * progress * (3 - 2 * progress)
    return 1 + (safeMaximum - 1) * smoothstep
  }

  static func racingSpeedMultiplier(
    brake: Double,
    accelerator: Double,
    minimumSpeed: Double,
    maximumSpeed: Double
  ) -> Double {
    let brakeAmount = min(max(brake, 0), 1)
    let acceleratorAmount = min(max(accelerator, 0), 1)
    let minimum = min(max(minimumSpeed, 0.05), 1)
    let maximum = max(maximumSpeed, 1)
    let brakeScale = 1 - (1 - minimum) * brakeAmount
    let acceleratorScale = 1 + (maximum - 1) * acceleratorAmount
    return brakeScale * acceleratorScale
  }
}

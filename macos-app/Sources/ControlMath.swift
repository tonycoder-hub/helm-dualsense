import CoreGraphics
import Foundation

enum ControlMath {
  static let maximumTimerGap: TimeInterval = 0.250
  static let safetyChordWindow: TimeInterval = 2.0
  static let stickDeadZone = 0.16
  static let stickPointerMaximumSpeed = 1_100.0
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
    let elapsed = min(max(deltaTime, 0), maximumTimerGap)
    let boost = stickHoldBoost(
      holdDuration: holdDuration,
      delay: stickAccelerationDelay,
      accelerationDuration: accelerationDuration,
      maximumBoost: maximumBoost
    )
    let distance = maximumSpeed * max(gain, 0) * shapedMagnitude * boost * elapsed
    return CGPoint(
      x: x / rawMagnitude * distance,
      y: y / rawMagnitude * distance
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
}

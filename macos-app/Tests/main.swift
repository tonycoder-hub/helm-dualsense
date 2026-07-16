import CoreGraphics
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

expect(
  ControlMath.safetyChordIsValid(modifierPressedAt: 10, buttonPressedAt: 12),
  "two-second chord boundary should be accepted"
)
expect(
  !ControlMath.safetyChordIsValid(modifierPressedAt: 10, buttonPressedAt: 12.001),
  "expired safety chord should be rejected"
)

var remainder = 0.0
expect(
  ControlMath.scrollDelta(
    axis: 0.1,
    deadZone: 0.18,
    gain: 8,
    deltaTime: 1.0 / 60.0,
    remainder: &remainder
  ) == 0,
  "scroll dead zone should suppress motion"
)
expect(
  ControlMath.scrollDelta(
    axis: 1,
    deadZone: 0.18,
    gain: 8,
    deltaTime: 1.0 / 60.0,
    remainder: &remainder
  ) == -8,
  "full downward stick should create deterministic scroll"
)

let pointer = ControlMath.pointerDelta(
  from: CGPoint(x: 0.1, y: 0.1),
  to: CGPoint(x: 0.9, y: 0.9),
  elapsed: 0.016,
  surfaceSize: CGSize(width: 1_920, height: 1_070),
  gain: 1,
  acceleration: 0.35,
  maximum: 180
)
expect(hypot(pointer.x, pointer.y) <= 180.001, "pointer delta should be capped")

let centeredStick = ControlMath.stickPointerDelta(
  x: 0.1,
  y: 0.1,
  deadZone: ControlMath.stickDeadZone,
  gain: 1,
  maximumSpeed: ControlMath.stickPointerMaximumSpeed,
  holdDuration: 0,
  accelerationDuration: 1.6,
  maximumBoost: 2.2,
  deltaTime: 1.0 / 60.0
)
expect(centeredStick == .zero, "radial stick dead zone should suppress drift")

let fullStick = ControlMath.stickPointerDelta(
  x: 1,
  y: 0,
  deadZone: ControlMath.stickDeadZone,
  gain: 1,
  maximumSpeed: 1_200,
  holdDuration: 0,
  accelerationDuration: 1.6,
  maximumBoost: 2.2,
  deltaTime: 1.0 / 60.0
)
expect(abs(fullStick.x - 20) < 0.001, "full stick speed should integrate by elapsed time")
expect(abs(fullStick.y) < 0.001, "horizontal stick motion should not move vertically")

let diagonalStick = ControlMath.stickPointerDelta(
  x: 1,
  y: 1,
  deadZone: ControlMath.stickDeadZone,
  gain: 1,
  maximumSpeed: 1_200,
  holdDuration: 0,
  accelerationDuration: 1.6,
  maximumBoost: 2.2,
  deltaTime: 1.0 / 60.0
)
expect(
  hypot(diagonalStick.x, diagonalStick.y) <= 20.001,
  "diagonal stick speed should be capped radially")

expect(
  ControlMath.stickHoldBoost(
    holdDuration: ControlMath.stickAccelerationDelay,
    delay: ControlMath.stickAccelerationDelay,
    accelerationDuration: 1.6,
    maximumBoost: 2.2
  ) == 1,
  "stick hold acceleration should wait for its delay"
)
let midBoost = ControlMath.stickHoldBoost(
  holdDuration: ControlMath.stickAccelerationDelay + 0.8,
  delay: ControlMath.stickAccelerationDelay,
  accelerationDuration: 1.6,
  maximumBoost: 2.2
)
expect(abs(midBoost - 1.6) < 0.001, "stick hold curve should use smoothstep at midpoint")
expect(
  ControlMath.stickHoldBoost(
    holdDuration: 99,
    delay: ControlMath.stickAccelerationDelay,
    accelerationDuration: 1.6,
    maximumBoost: 2.2
  ) == 2.2,
  "stick hold acceleration should cap at its configured boost"
)

let mappingData = try! JSONEncoder().encode(ControllerMapping.standard)
let decodedMapping = try! JSONDecoder().decode(ControllerMapping.self, from: mappingData)
expect(decodedMapping == .standard, "controller mapping should persist losslessly")
expect(ControlMath.maximumTimerGap == 0.250, "timer-gap contract changed unexpectedly")

let audioInputs = AudioInputCatalog.devices()
expect(!audioInputs.isEmpty, "at least one Mac-supported audio input should be discoverable")
expect(audioInputs.contains(where: { $0.isDefault }), "default audio input should be identified")

print("CONTROL_MATH_AND_AUDIO_TESTS=PASS inputs=\(audioInputs.count)")

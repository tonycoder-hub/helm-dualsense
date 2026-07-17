import CoreGraphics
import Foundation

struct ContinuousScrollSample: Equatable {
  let precisePixels: Double
  let pointPixels: Int32

  static let zero = ContinuousScrollSample(precisePixels: 0, pointPixels: 0)
}

struct ContinuousScrollAccumulator {
  private static let startupPointThreshold = 0.125
  private var pointRemainder = 0.0
  private var activeDirection: Int32 = 0
  private var emittedStartupPoint = false

  mutating func update(precisePixels: Double) -> ContinuousScrollSample {
    guard precisePixels.isFinite, precisePixels != 0 else {
      reset()
      return .zero
    }

    let direction: Int32 = precisePixels < 0 ? -1 : 1
    if direction != activeDirection {
      pointRemainder = 0
      activeDirection = direction
      emittedStartupPoint = false
    }

    pointRemainder += precisePixels
    var pointPixels = Int32(pointRemainder.rounded(.towardZero))
    if pointPixels == 0, !emittedStartupPoint,
      abs(pointRemainder) >= Self.startupPointThreshold
    {
      pointPixels = direction
    }
    if pointPixels != 0 {
      pointRemainder -= Double(pointPixels)
      emittedStartupPoint = true
    }
    return ContinuousScrollSample(
      precisePixels: precisePixels,
      pointPixels: pointPixels
    )
  }

  mutating func reset() {
    pointRemainder = 0
    activeDirection = 0
    emittedStartupPoint = false
  }
}

enum ContinuousScrollEventFactory {
  static func make(sample: ContinuousScrollSample) -> CGEvent? {
    guard sample.precisePixels.isFinite,
      sample.precisePixels != 0 || sample.pointPixels != 0
    else { return nil }
    guard
      let event = CGEvent(
        scrollWheelEvent2Source: nil,
        units: .pixel,
        wheelCount: 1,
        wheel1: sample.pointPixels,
        wheel2: 0,
        wheel3: 0
      )
    else { return nil }
    event.setDoubleValueField(
      .scrollWheelEventFixedPtDeltaAxis1,
      value: sample.precisePixels
    )
    event.setIntegerValueField(
      .scrollWheelEventPointDeltaAxis1,
      value: Int64(sample.pointPixels)
    )
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    return event
  }
}

import CoreGraphics
import Foundation

struct DisplaySynchronizedMotionFrame: Equatable {
  let pointer: CGPoint
  let scrollPixels: Double
  let hasScrollSample: Bool
  let scrollGestureEnded: Bool

  static let zero = DisplaySynchronizedMotionFrame(
    pointer: .zero,
    scrollPixels: 0,
    hasScrollSample: false,
    scrollGestureEnded: false
  )
}

struct DisplaySynchronizedMotionAccumulator {
  private var pointer = CGPoint.zero
  private var scrollPixels = 0.0
  private var hasScrollSample = false
  private var scrollGestureEnded = false

  mutating func add(
    pointer delta: CGPoint,
    scrollPixels: Double?,
    scrollGestureEnded: Bool = false
  ) {
    if delta.x.isFinite, delta.y.isFinite {
      pointer.x += delta.x
      pointer.y += delta.y
    }
    if let scrollPixels, scrollPixels.isFinite {
      self.scrollPixels += scrollPixels
      hasScrollSample = true
    }
    self.scrollGestureEnded = self.scrollGestureEnded || scrollGestureEnded
  }

  mutating func drain() -> DisplaySynchronizedMotionFrame {
    let frame = DisplaySynchronizedMotionFrame(
      pointer: pointer,
      scrollPixels: scrollPixels,
      hasScrollSample: hasScrollSample,
      scrollGestureEnded: scrollGestureEnded
    )
    reset()
    return frame
  }

  mutating func reset() {
    pointer = .zero
    scrollPixels = 0
    hasScrollSample = false
    scrollGestureEnded = false
  }
}

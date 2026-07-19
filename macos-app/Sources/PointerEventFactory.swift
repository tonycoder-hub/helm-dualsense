import CoreGraphics
import Foundation

enum PointerDesktopGeometry {
  static func projectedTarget(
    origin: CGPoint,
    delta: CGPoint,
    displayBounds bounds: [CGRect]
  ) -> CGPoint? {
    guard origin.x.isFinite, origin.y.isFinite,
      delta.x.isFinite, delta.y.isFinite
    else { return nil }
    let validBounds = bounds.filter {
      $0.origin.x.isFinite && $0.origin.y.isFinite
        && $0.width.isFinite && $0.height.isFinite
        && $0.width >= 1 && $0.height >= 1
    }
    guard !validBounds.isEmpty else { return nil }

    let desired = CGPoint(x: origin.x + delta.x, y: origin.y + delta.y)
    if validBounds.contains(where: { contains(desired, in: $0) }) {
      return desired
    }

    var nearestPoint: CGPoint?
    var nearestSquaredDistance = Double.infinity
    for bounds in validBounds {
      let candidate = CGPoint(
        x: min(max(desired.x, bounds.minX), bounds.maxX - 1),
        y: min(max(desired.y, bounds.minY), bounds.maxY - 1)
      )
      let squaredDistance = pow(candidate.x - desired.x, 2)
        + pow(candidate.y - desired.y, 2)
      if squaredDistance < nearestSquaredDistance {
        nearestPoint = candidate
        nearestSquaredDistance = squaredDistance
      }
    }
    return nearestPoint
  }

  private static func contains(_ point: CGPoint, in bounds: CGRect) -> Bool {
    point.x >= bounds.minX && point.x < bounds.maxX
      && point.y >= bounds.minY && point.y < bounds.maxY
  }
}

enum PointerEventFactory {
  private static let eventSource: CGEventSource? = {
    guard let source = CGEventSource(stateID: .hidSystemState) else { return nil }
    source.localEventsSuppressionInterval = 0
    return source
  }()

  static func make(
    origin: CGPoint,
    delta: CGPoint,
    displayBounds: [CGRect],
    mouseType: CGEventType,
    mouseButton: CGMouseButton
  ) -> CGEvent? {
    guard
      let target = PointerDesktopGeometry.projectedTarget(
        origin: origin,
        delta: delta,
        displayBounds: displayBounds
      ),
      let eventSource
    else { return nil }
    guard
      let event = CGEvent(
        mouseEventSource: eventSource,
        mouseType: mouseType,
        mouseCursorPosition: target,
        mouseButton: mouseButton
      )
    else { return nil }

    event.flags.insert(.maskNonCoalesced)
    event.setIntegerValueField(
      .mouseEventDeltaX,
      value: hardwareDelta(target.x - origin.x)
    )
    event.setIntegerValueField(
      .mouseEventDeltaY,
      value: hardwareDelta(target.y - origin.y)
    )
    return event
  }

  static func makeButtonEvent(
    location: CGPoint,
    button: CGMouseButton,
    pressed: Bool
  ) -> CGEvent? {
    guard location.x.isFinite, location.y.isFinite, let eventSource else { return nil }
    let eventType: CGEventType
    switch button {
    case .left: eventType = pressed ? .leftMouseDown : .leftMouseUp
    case .right: eventType = pressed ? .rightMouseDown : .rightMouseUp
    default: return nil
    }
    return CGEvent(
      mouseEventSource: eventSource,
      mouseType: eventType,
      mouseCursorPosition: location,
      mouseButton: button
    )
  }

  private static func hardwareDelta(_ value: Double) -> Int64 {
    guard value.isFinite, value != 0 else { return 0 }
    let rounded = Int64(value.rounded())
    if rounded != 0 { return rounded }
    return value < 0 ? -1 : 1
  }
}

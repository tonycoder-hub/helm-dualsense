import Foundation

enum HapticFeedbackKind: CaseIterable {
  case controlEnabled
  case primaryAction
  case secondaryAction
  case navigation
  case shortcut
  case voiceStart
  case voiceStop
  case warning
  case preview
}

struct HapticPulse: Equatable {
  let lowFrequency: UInt16
  let highFrequency: UInt16
  let durationMilliseconds: UInt32
}

protocol HapticBackend {
  func isAvailable() -> Bool
  func play(_ pulse: HapticPulse) -> Bool
  func stop()
}

enum HapticFeedbackPolicy {
  static let defaultEnabled = false
  static let defaultIntensity = 0.35

  static func shouldPlay(
    enabled: Bool,
    intensity: Double,
    available: Bool,
    connected: Bool,
    controlsEnabled: Bool,
    allowsDisabledControls: Bool
  ) -> Bool {
    enabled && intensity > 0 && available && connected
      && (controlsEnabled || allowsDisabledControls)
  }

  static func pulse(for kind: HapticFeedbackKind, intensity: Double) -> HapticPulse {
    let envelope: (low: Double, high: Double, duration: UInt32)
    switch kind {
    case .controlEnabled:
      envelope = (0.20, 0.40, 42)
    case .primaryAction:
      envelope = (0.07, 0.34, 22)
    case .secondaryAction:
      envelope = (0.20, 0.18, 28)
    case .navigation:
      envelope = (0.10, 0.26, 18)
    case .shortcut:
      envelope = (0.09, 0.32, 24)
    case .voiceStart:
      envelope = (0.05, 0.30, 34)
    case .voiceStop:
      envelope = (0.17, 0.08, 30)
    case .warning:
      envelope = (0.42, 0.10, 72)
    case .preview:
      envelope = (0.20, 0.38, 58)
    }
    let amount = min(max(intensity, 0), 1)
    return HapticPulse(
      lowFrequency: channel(envelope.low, intensity: amount),
      highFrequency: channel(envelope.high, intensity: amount),
      durationMilliseconds: envelope.duration
    )
  }

  private static func channel(_ tunedLevel: Double, intensity: Double) -> UInt16 {
    UInt16((min(max(tunedLevel * intensity, 0), 1) * Double(UInt16.max)).rounded())
  }
}

struct HapticCoordinator {
  private var rateLimiter: HapticRateLimiter

  init(minimumInterval: TimeInterval) {
    rateLimiter = HapticRateLimiter(minimumInterval: minimumInterval)
  }

  mutating func play(
    _ kind: HapticFeedbackKind,
    intensity: Double,
    enabled: Bool,
    connected: Bool,
    controlsEnabled: Bool,
    allowsDisabledControls: Bool,
    now: TimeInterval,
    backend: HapticBackend
  ) -> Bool {
    guard
      HapticFeedbackPolicy.shouldPlay(
        enabled: enabled,
        intensity: intensity,
        available: backend.isAvailable(),
        connected: connected,
        controlsEnabled: controlsEnabled,
        allowsDisabledControls: allowsDisabledControls
      ),
      rateLimiter.accepts(now: now)
    else { return false }
    let pulse = HapticFeedbackPolicy.pulse(for: kind, intensity: intensity)
    guard backend.play(pulse) else {
      rateLimiter.reset()
      return false
    }
    return true
  }

  mutating func stop(backend: HapticBackend) {
    backend.stop()
    rateLimiter.reset()
  }
}

struct HapticRateLimiter {
  let minimumInterval: TimeInterval
  private var lastAcceptedAt: TimeInterval?

  init(minimumInterval: TimeInterval) {
    self.minimumInterval = max(minimumInterval, 0)
  }

  mutating func accepts(now: TimeInterval) -> Bool {
    if let lastAcceptedAt, now >= lastAcceptedAt,
      now - lastAcceptedAt + 1e-9 < minimumInterval
    {
      return false
    }
    lastAcceptedAt = now
    return true
  }

  mutating func reset() {
    lastAcceptedAt = nil
  }
}

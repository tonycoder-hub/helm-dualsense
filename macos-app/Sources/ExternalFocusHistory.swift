import Foundation

struct ExternalProcessIdentity: Equatable {
  let processIdentifier: Int32
  let launchTime: TimeInterval
}

enum ExternalProcessIdentityPolicy {
  static func matches(
    expected: ExternalProcessIdentity,
    candidateProcessIdentifier: Int32,
    candidateLaunchTime: TimeInterval?
  ) -> Bool {
    guard let candidateLaunchTime else { return false }
    return candidateProcessIdentifier == expected.processIdentifier
      && candidateLaunchTime == expected.launchTime
  }
}

struct ExternalFocusHistory {
  private(set) var lastExternalProcessIdentifier: Int32?
  private(set) var activationGeneration: UInt64 = 0
  private var lastExternalProcessIdentity: ExternalProcessIdentity?

  mutating func recordActivation(
    processIdentifier: Int32,
    processLaunchTime: TimeInterval? = nil,
    helmProcessIdentifier: Int32
  ) {
    guard processIdentifier > 0, processIdentifier != helmProcessIdentifier else { return }
    activationGeneration &+= 1
    lastExternalProcessIdentifier = processIdentifier
    lastExternalProcessIdentity = processLaunchTime.map {
      ExternalProcessIdentity(processIdentifier: processIdentifier, launchTime: $0)
    }
  }

  func manualRetryTarget(after activationBaseline: UInt64) -> ExternalProcessIdentity? {
    guard activationGeneration > activationBaseline else { return nil }
    return lastExternalProcessIdentity
  }

  func restorationTarget(
    currentProcessIdentifier: Int32,
    helmProcessIdentifier: Int32
  ) -> Int32? {
    guard currentProcessIdentifier == helmProcessIdentifier else { return nil }
    return lastExternalProcessIdentifier
  }

  func insertionTarget(
    currentProcessIdentifier: Int32,
    helmProcessIdentifier: Int32
  ) -> Int32? {
    if currentProcessIdentifier > 0, currentProcessIdentifier != helmProcessIdentifier {
      return currentProcessIdentifier
    }
    guard currentProcessIdentifier == helmProcessIdentifier else { return nil }
    return lastExternalProcessIdentifier
  }

  func restorationTargets(
    currentProcessIdentifier: Int32,
    helmProcessIdentifier: Int32,
    fallbackProcessIdentifiers: [Int32]
  ) -> [Int32] {
    guard currentProcessIdentifier == helmProcessIdentifier else { return [] }
    var targets: [Int32] = []
    let candidates =
      [lastExternalProcessIdentifier].compactMap { $0 }
      + fallbackProcessIdentifiers
    for identifier in candidates
    where identifier > 0 && identifier != helmProcessIdentifier && !targets.contains(identifier) {
      targets.append(identifier)
    }
    return targets
  }
}

struct VoiceTestSessionGeneration {
  private var value: UInt64 = 0

  mutating func begin() -> UInt64 {
    value &+= 1
    return value
  }

  mutating func invalidate() {
    value &+= 1
  }

  func accepts(_ token: UInt64) -> Bool {
    token == value
  }
}

enum VoiceInsertionTargetPolicy {
  static func deliveryTarget(
    capturedProcessIdentifier: Int32?,
    currentProcessIdentifier: Int32,
    helmProcessIdentifier: Int32
  ) -> Int32? {
    guard let capturedProcessIdentifier,
      capturedProcessIdentifier > 0,
      capturedProcessIdentifier != helmProcessIdentifier
    else { return nil }
    return capturedProcessIdentifier
  }
}

enum VoiceTextDeliveryRetryPolicy {
  static func nextAttemptCount(from attemptsRemaining: Int) -> Int? {
    guard attemptsRemaining > 0 else { return nil }
    return attemptsRemaining - 1
  }
}

enum VoiceManualDeliveryPolicy {
  static func deliverableText(
    _ text: String?,
    isListening: Bool,
    isFinalizing: Bool,
    deliveryInProgress: Bool
  ) -> String? {
    guard !isListening, !isFinalizing, !deliveryInProgress, let text,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return text
  }
}

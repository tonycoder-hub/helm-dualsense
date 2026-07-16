import Foundation

struct ExternalFocusHistory {
  private(set) var lastExternalProcessIdentifier: Int32?

  mutating func recordActivation(
    processIdentifier: Int32,
    helmProcessIdentifier: Int32
  ) {
    guard processIdentifier > 0, processIdentifier != helmProcessIdentifier else { return }
    lastExternalProcessIdentifier = processIdentifier
  }

  func restorationTarget(
    currentProcessIdentifier: Int32,
    helmProcessIdentifier: Int32
  ) -> Int32? {
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

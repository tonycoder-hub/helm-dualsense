import Foundation

struct PermissionDiagnosticSnapshot: Equatable {
  let accessibilityGranted: Bool
  let microphoneRawValue: Int
  let speechRawValue: Int

  var logMessage: String {
    "permission_snapshot accessibility=\(accessibilityGranted ? 1 : 0) "
      + "microphone=\(microphoneRawValue) speech=\(speechRawValue)"
  }
}

struct PermissionDiagnosticTracker {
  private var previousSnapshot: PermissionDiagnosticSnapshot?

  mutating func recordIfChanged(
    _ snapshot: PermissionDiagnosticSnapshot
  ) -> PermissionDiagnosticSnapshot? {
    guard snapshot != previousSnapshot else { return nil }
    previousSnapshot = snapshot
    return snapshot
  }
}

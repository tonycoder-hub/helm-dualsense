import Foundation

enum TextInsertionDecision: Equatable {
  case accessibilitySelectedText
  case unicodeKeyboardEvents
  case refused
}

enum TextInsertionDeliveryConfidence: Equatable {
  case confirmedInsertion
  case unconfirmedDispatch
}

enum ExternalTextFocusReadiness: Equatable {
  case ready
  case retry
  case refused
}

enum UnicodeEventPostingRoute: Equatable {
  case globalHID
  case refused
}

enum ExternalFocusedElementSource: Equatable {
  case systemWide
  case application
  case unavailable
}

enum VoiceFocusSnapshotResolution: Equatable {
  case useCapturedFocus
  case recaptureCurrentExternalFocus
  case retryAfterActivation
  case refuse
}

enum UnicodeTextEventPlanner {
  static func chunks(for text: String) -> [String] {
    text.map(String.init)
  }
}

enum UnicodeDeliveryProgress {
  static func remainingText(chunks: [String], sentCount: Int) -> String {
    let safeCount = min(max(sentCount, 0), chunks.count)
    return chunks.dropFirst(safeCount).joined()
  }

  static func completedUnconfirmedText(chunks: [String]) -> String {
    chunks.joined()
  }
}

enum AccessibilityTextWriteVerification: Equatable {
  case confirmed
  case unchanged
  case diverged
  case unverifiable

  static func evaluate(
    before: String?,
    expected: String?,
    after: String?
  ) -> AccessibilityTextWriteVerification {
    guard let before, let expected, let after else { return .unverifiable }
    if after == expected { return .confirmed }
    if after == before { return .unchanged }
    return .diverged
  }
}

enum TextInsertionPolicy {
  static func voiceFocusSnapshotResolution(
    hasCapturedSnapshot: Bool,
    targetIsFrontmost: Bool,
    processIdentityMatches: Bool
  ) -> VoiceFocusSnapshotResolution {
    guard processIdentityMatches else { return .refuse }
    guard targetIsFrontmost else { return .retryAfterActivation }
    return hasCapturedSnapshot ? .useCapturedFocus : .recaptureCurrentExternalFocus
  }

  static func focusedElementSource(
    expectedProcessIdentifier: Int32,
    systemWideProcessIdentifier: Int32?,
    applicationProcessIdentifier: Int32?,
    allowsApplicationFallback: Bool
  ) -> ExternalFocusedElementSource {
    if systemWideProcessIdentifier == expectedProcessIdentifier {
      return .systemWide
    }
    if allowsApplicationFallback,
      applicationProcessIdentifier == expectedProcessIdentifier
    {
      return .application
    }
    return .unavailable
  }

  static func retryText(
    after confidence: TextInsertionDeliveryConfidence,
    originalText: String
  ) -> String? {
    switch confidence {
    case .confirmedInsertion: return nil
    case .unconfirmedDispatch: return originalText
    }
  }

  static func unicodeEventPostingRoute(
    confirmedExternalTarget: Bool,
    focusReadiness: ExternalTextFocusReadiness?,
    secureInputEnabled: Bool
  ) -> UnicodeEventPostingRoute {
    guard !secureInputEnabled else { return .refused }
    guard confirmedExternalTarget else { return .refused }
    return focusReadiness == .ready ? .globalHID : .refused
  }

  static func externalFocusReadiness(
    expectedProcessIdentifier: Int32,
    helmProcessIdentifier: Int32,
    frontmostProcessIdentifier: Int32?,
    focusedElementProcessIdentifier: Int32?
  ) -> ExternalTextFocusReadiness {
    guard expectedProcessIdentifier > 0,
      expectedProcessIdentifier != helmProcessIdentifier
    else { return .refused }
    guard frontmostProcessIdentifier == expectedProcessIdentifier,
      focusedElementProcessIdentifier == expectedProcessIdentifier
    else { return .retry }
    return .ready
  }

  static func decision(
    secureInputEnabled: Bool,
    secureField: Bool,
    focusedRole: String?,
    selectedTextSettable: Bool,
    selectedTextStateReadable: Bool,
    confirmedExternalTarget: Bool = false
  ) -> TextInsertionDecision {
    guard !secureInputEnabled, !secureField else { return .refused }
    if selectedTextSettable, selectedTextStateReadable {
      return .accessibilitySelectedText
    }
    let knownEditableRole = focusedRole.map {
      ["AXTextField", "AXTextArea", "AXComboBox"].contains($0)
    } ?? false
    guard knownEditableRole || confirmedExternalTarget else { return .refused }
    return .unicodeKeyboardEvents
  }

  static func deliveryConfidence(
    for decision: TextInsertionDecision
  ) -> TextInsertionDeliveryConfidence? {
    switch decision {
    case .accessibilitySelectedText: return .confirmedInsertion
    case .unicodeKeyboardEvents: return .unconfirmedDispatch
    case .refused: return nil
    }
  }
}

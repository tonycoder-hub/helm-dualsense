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

enum TextInsertionPolicy {
  static func unicodeEventPostingRoute(
    confirmedExternalTarget: Bool,
    focusReadiness: ExternalTextFocusReadiness?,
    secureInputEnabled: Bool
  ) -> UnicodeEventPostingRoute {
    guard !secureInputEnabled else { return .refused }
    guard confirmedExternalTarget else { return .globalHID }
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
    confirmedExternalTarget: Bool = false
  ) -> TextInsertionDecision {
    guard !secureInputEnabled, !secureField else { return .refused }
    if selectedTextSettable { return .accessibilitySelectedText }
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

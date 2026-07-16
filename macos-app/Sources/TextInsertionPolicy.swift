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

enum TextInsertionPolicy {
  static func decision(
    secureInputEnabled: Bool,
    secureField: Bool,
    focusedRole: String?,
    selectedTextSettable: Bool
  ) -> TextInsertionDecision {
    guard !secureInputEnabled, !secureField else { return .refused }
    if selectedTextSettable { return .accessibilitySelectedText }
    guard let focusedRole,
      ["AXTextField", "AXTextArea", "AXComboBox"].contains(focusedRole)
    else { return .refused }
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

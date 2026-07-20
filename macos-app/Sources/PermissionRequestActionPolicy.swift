import Foundation

enum PermissionGrantState: String {
  case notDetermined
  case denied
  case restricted
  case authorized
}

enum PermissionRequestAction: Equatable {
  case requestAccessibility
  case openAccessibilitySettings
  case requestMicrophone
  case requestSpeech
  case openMicrophoneSettings
  case openSpeechSettings
}

enum PermissionRequestActionPolicy {
  static func accessibility(isTrusted: Bool) -> PermissionRequestAction {
    isTrusted ? .openAccessibilitySettings : .requestAccessibility
  }

  static func voice(
    microphone: PermissionGrantState,
    speech: PermissionGrantState
  ) -> PermissionRequestAction {
    switch microphone {
    case .notDetermined:
      return .requestMicrophone
    case .denied, .restricted:
      return .openMicrophoneSettings
    case .authorized:
      break
    }

    switch speech {
    case .notDetermined:
      return .requestSpeech
    case .denied, .restricted:
      return .openSpeechSettings
    case .authorized:
      return .openMicrophoneSettings
    }
  }
}

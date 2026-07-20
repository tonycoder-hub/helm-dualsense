import Foundation

@main
struct PermissionRequestActionPolicyTests {
  static func main() {
    expect(
      PermissionRequestActionPolicy.accessibility(isTrusted: false),
      .requestAccessibility,
      "untrusted accessibility should request permission"
    )
    expect(
      PermissionRequestActionPolicy.accessibility(isTrusted: true),
      .openAccessibilitySettings,
      "trusted accessibility should open settings for visible management"
    )

    expectVoice(.notDetermined, .notDetermined, .requestMicrophone)
    expectVoice(.denied, .authorized, .openMicrophoneSettings)
    expectVoice(.restricted, .authorized, .openMicrophoneSettings)
    expectVoice(.authorized, .notDetermined, .requestSpeech)
    expectVoice(.authorized, .denied, .openSpeechSettings)
    expectVoice(.authorized, .restricted, .openSpeechSettings)
    expectVoice(.authorized, .authorized, .openMicrophoneSettings)

    print("PERMISSION_REQUEST_ACTION_POLICY_TESTS=PASS")
  }

  private static func expectVoice(
    _ microphone: PermissionGrantState,
    _ speech: PermissionGrantState,
    _ expected: PermissionRequestAction
  ) {
    expect(
      PermissionRequestActionPolicy.voice(microphone: microphone, speech: speech),
      expected,
      "unexpected voice permission action for microphone=\(microphone) speech=\(speech)"
    )
  }

  private static func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    guard actual == expected else {
      fputs("FAIL: \(message); actual=\(actual) expected=\(expected)\n", stderr)
      exit(1)
    }
  }
}

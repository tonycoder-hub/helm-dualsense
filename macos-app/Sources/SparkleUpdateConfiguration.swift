import Foundation

enum SparkleUpdateConfigurationPolicy {
  static func isConfigured(info: [String: Any]) -> Bool {
    guard
      let feedURL = info["SUFeedURL"] as? String,
      let components = URLComponents(string: feedURL),
      components.scheme == "https",
      components.host?.isEmpty == false,
      let publicKey = info["SUPublicEDKey"] as? String,
      !publicKey.isEmpty,
      info["SURequireSignedFeed"] as? Bool == true,
      info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
      info["SUEnableAutomaticChecks"] as? Bool == false,
      let failureExpiration = info["SUSignedFeedFailureExpirationInterval"] as? NSNumber,
      failureExpiration.doubleValue == 0
    else { return false }
    return true
  }
}

import Foundation
import Sparkle

@MainActor
final class HelmUpdateController {
  let isConfigured: Bool
  private let updaterController: SPUStandardUpdaterController?

  init(bundle: Bundle = .main) {
    let info = bundle.infoDictionary ?? [:]
    let feedURL = info["SUFeedURL"] as? String
    let publicKey = info["SUPublicEDKey"] as? String
    let requiresSignedFeed = info["SURequireSignedFeed"] as? Bool
    let automaticChecks = info["SUEnableAutomaticChecks"] as? Bool
    let configured =
      feedURL?.hasPrefix("https://") == true
      && publicKey?.isEmpty == false
      && requiresSignedFeed == true
      && automaticChecks == false
    isConfigured = configured
    updaterController =
      configured
      ? SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
      )
      : nil
  }

  @discardableResult
  func checkForUpdates() -> Bool {
    guard let updaterController else { return false }
    updaterController.checkForUpdates(nil)
    return true
  }
}

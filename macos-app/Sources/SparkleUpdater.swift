import Foundation
import Sparkle

@MainActor
final class HelmUpdateController {
  let isConfigured: Bool
  private let updaterController: SPUStandardUpdaterController?

  init(bundle: Bundle = .main) {
    let info = bundle.infoDictionary ?? [:]
    let configured = SparkleUpdateConfigurationPolicy.isConfigured(info: info)
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

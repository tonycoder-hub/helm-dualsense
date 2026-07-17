import Foundation

enum MappingLayoutPolicy {
  static let minimumShortcutEditorWidth = 300.0
  static let shortcutSpacing = 12.0

  static func shortcutColumnCount(for availableWidth: Double) -> Int {
    let safeWidth = max(availableWidth, 0)
    let count = Int(
      floor(
        (safeWidth + shortcutSpacing)
          / (minimumShortcutEditorWidth + shortcutSpacing)
      )
    )
    return min(max(count, 1), 3)
  }
}

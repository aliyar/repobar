import SwiftUI

/// True while rendering views offscreen (previews, README screenshots): lists lay out at their natural
/// height instead of scrolling, because `ImageRenderer` never runs the geometry callbacks that size them.
private struct StaticLayoutKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var staticLayout: Bool {
        get { self[StaticLayoutKey.self] }
        set { self[StaticLayoutKey.self] = newValue }
    }
}

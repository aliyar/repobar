import AppKit
import SwiftUI

/// Renders `StatusItemView` into a non-template `NSImage` so the menu bar shows real colors.
/// The glyph color is chosen from the status item's effective appearance (light vs. dark menu bar).
final class StatusItemRenderer {
    func image(for layout: StatusItemLayout, appearance: NSAppearance, scale: CGFloat) -> NSImage? {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let foreground: Color = isDark ? .white.opacity(0.92) : .black.opacity(0.88)
        let view = StatusItemView(layout: layout, foreground: foreground)
            .environment(\.colorScheme, isDark ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = max(1, scale)
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = false
        return image
    }
}

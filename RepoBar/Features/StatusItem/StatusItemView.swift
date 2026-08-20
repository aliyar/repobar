import SwiftUI

/// The menu-bar glyph plus per-repository dots / count. Rendered to an image by `StatusItemRenderer`
/// (so it can be colored), and shown live in Settings as a preview.
struct StatusItemView: View {
    let layout: StatusItemLayout
    /// Glyph/text color chosen by the caller from the menu bar's effective appearance.
    let foreground: Color

    static let height: CGFloat = 18
    static let dotSize: CGFloat = 6

    var body: some View {
        HStack(spacing: 4) {
            glyph
            if !layout.dots.isEmpty {
                HStack(spacing: 3) {
                    ForEach(Array(layout.dots.enumerated()), id: \.offset) { _, dot in
                        DotView(dot: dot, foreground: foreground)
                    }
                }
            }
            if layout.overflow > 0 {
                Text("+\(layout.overflow)")
                    .font(.system(size: 9, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(foreground)
            }
            if let text = layout.text {
                Text(text)
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(foreground)
            }
        }
        .padding(.horizontal, 2)
        .frame(height: Self.height)
        .fixedSize()
    }

    private var glyph: some View {
        Image(systemName: layout.glyph == .paused ? "pause.circle" : "arrow.triangle.branch")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(foreground.opacity(layout.glyphOpacity))
            .overlay(alignment: .topTrailing) {
                if layout.showsAttentionDot {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                        .offset(x: 2, y: -1)
                }
            }
    }
}

private struct DotView: View {
    let dot: StatusItemLayout.Dot
    let foreground: Color

    var body: some View {
        ZStack {
            switch dot.fill {
            case .filled:
                Circle().fill(dot.color.color)
            case .faded:
                Circle().fill(dot.color.color.opacity(0.32))
            case .ring:
                Circle().strokeBorder(dot.color.color, lineWidth: 1.2)
            case .error:
                Circle().strokeBorder(dot.color.color, lineWidth: 1.2)
                Text("!")
                    .font(.system(size: 5.5, weight: .heavy))
                    .foregroundStyle(dot.color.color)
            }
        }
        .frame(width: StatusItemView.dotSize, height: StatusItemView.dotSize)
    }
}

#Preview("Dots") {
    VStack(alignment: .leading, spacing: 8) {
        StatusItemView(layout: .make(from: .sample), foreground: .black).padding(4).background(.white)
        StatusItemView(layout: .make(from: .sample), foreground: .white).padding(4).background(.black)
    }
    .padding()
}

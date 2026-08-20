import SwiftUI

/// The repository's color dot as used in panel rows: filled = new commits, hollow = idle, ring + "!" = error.
struct StatusDotView: View {
    let item: RepoItem
    var size: CGFloat = 9

    var body: some View {
        ZStack {
            switch item.status {
            case .unseen:
                Circle().fill(item.color.color)
            case .error:
                Circle().strokeBorder(item.color.color, lineWidth: 1.5)
                Text("!").font(.system(size: size * 0.7, weight: .heavy)).foregroundStyle(item.color.color)
            case .checking, .waitingForFirstCheck:
                Circle().strokeBorder(item.color.color.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
            case .idle:
                Circle().strokeBorder(item.color.color, lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

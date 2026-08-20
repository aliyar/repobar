import SwiftUI
import GitEngine

struct CommitRow: View {
    let commit: IncomingCommit
    let hasWebURL: Bool
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(commit.shortSHA)
                    .font(.caption.monospaced())
                    .foregroundStyle(commit.isNew ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(commit.subject)
                        .font(.caption.weight(commit.isNew ? .medium : .regular))
                        .foregroundStyle(commit.isNew ? .primary : .secondary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(commit.authorName)
                        Text("·")
                        RelativeTimeText(date: commit.authorDate)
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if hasWebURL && hovering {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(hovering ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
        .help(hasWebURL ? "Open commit on the web" : "")
        .accessibilityLabel(Text("\(commit.subject), \(commit.authorName)"))
    }
}

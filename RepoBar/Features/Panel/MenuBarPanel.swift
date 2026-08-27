import SwiftUI
import OSLog
import GitEngine

/// Root of the popover.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelUIState.self) private var ui
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let width: CGFloat = 340

    var body: some View {
        @Bindable var ui = ui
        VStack(spacing: 0) {
            PanelHeader()
            Divider()
            content
            if let toast = model.toast {
                ToastView(toast: toast)
                    .transition(reduceMotion ? .identity : .move(edge: .bottom).combined(with: .opacity))
            }
            Divider()
            PanelFooter()
        }
        .frame(width: Self.width)
        // The popover's own vibrancy lets a busy wallpaper bleed through the commit
        // list; a translucent ground over it keeps the text readable while the panel
        // still reads as a popover rather than an opaque window.
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.55))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.toast)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.pendingDiscovery)
        .overlay {
            if ui.isDropTargeted && !model.records.isEmpty {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    .overlay { Text("Drop to add").font(.headline).foregroundStyle(Color.accentColor) }
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            guard !folders.isEmpty else { return false }
            Task { await model.addRepositories(folders) }
            return true
        } isTargeted: { ui.isDropTargeted = $0 }
    }

    @ViewBuilder
    private var content: some View {
        if let proposal = model.pendingDiscovery {
            DiscoveryProposalView(proposal: proposal)
            if !model.records.isEmpty { Divider() }
        }
        if model.records.isEmpty {
            if model.pendingDiscovery == nil {
                EmptyStateView(isTargeted: ui.isDropTargeted)
            }
        } else {
            RepoListView()
        }
    }
}

struct DiscoveryProposalView: View {
    let proposal: DiscoveryProposal
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(proposal.folder.lastPathComponent) isn't a repository, but contains \(proposal.repositories.count):")
                .font(.caption.weight(.medium))
            Text(proposal.repositories.map(\.lastPathComponent).joined(separator: ", "))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                Button("Add all \(proposal.repositories.count)") { model.confirmDiscovery() }
                    .keyboardShortcut(.defaultAction)
                Button("Cancel") { model.dismissDiscovery() }
                    .keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06))
    }
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(toast.message).font(.caption).lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(tint.opacity(0.08))
    }

    private var symbol: String {
        switch toast.kind {
        case .info: "info.circle"
        case .success: "checkmark.circle"
        case .failure: "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch toast.kind {
        case .info: .secondary
        case .success: .green
        case .failure: .red
        }
    }
}

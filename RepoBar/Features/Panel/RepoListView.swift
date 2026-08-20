import SwiftUI
import GitEngine

struct RepoListView: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelUIState.self) private var ui
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.staticLayout) private var staticLayout
    @State private var contentHeight: CGFloat = 0
    @FocusState private var searchFocused: Bool

    static let maxHeight: CGFloat = 460
    private var showsSearch: Bool { model.records.count > 8 }

    var body: some View {
        @Bindable var ui = ui
        let items = model.sortedItems(matching: ui.searchText)
        VStack(spacing: 0) {
            if showsSearch {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                    TextField("Filter repositories", text: $ui.searchText)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .focused($searchFocused)
                    if !ui.searchText.isEmpty {
                        Button { ui.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                .padding(.horizontal, 10)
                .padding(.top, 6)
                Button("") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            }
            if staticLayout {
                rows(items).padding(.horizontal, 6).padding(.vertical, 6)
            } else {
                ScrollView {
                    rows(items)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                        .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.1), value: items.map(\.id))
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { height in
                            contentHeight = height
                        }
                }
                .frame(height: min(max(contentHeight, 44), Self.maxHeight))
            }
        }
    }

    @ViewBuilder
    private func rows(_ items: [RepoItem]) -> some View {
        LazyVStack(spacing: 1) {
            ForEach(items) { item in
                if ui.confirmingRemoval == item.id {
                    RemovalConfirmation(item: item)
                } else {
                    RepoRow(item: item)
                }
            }
        }
    }
}

struct RemovalConfirmation: View {
    let item: RepoItem
    @Environment(AppModel.self) private var model
    @Environment(PanelUIState.self) private var ui

    var body: some View {
        HStack(spacing: 8) {
            StatusDotView(item: item)
            Text("Remove \(item.name)?").font(.body.weight(.medium)).lineLimit(1)
            Spacer()
            Button("Cancel") { ui.confirmingRemoval = nil }
            Button("Remove", role: .destructive) {
                ui.confirmingRemoval = nil
                ui.expanded.remove(item.id)
                model.remove(item.id)
            }
            .tint(.red)
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

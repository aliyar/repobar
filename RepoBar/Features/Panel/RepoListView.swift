import SwiftUI
import GitEngine

struct RepoListView: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelUIState.self) private var ui
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.staticLayout) private var staticLayout
    @State private var contentHeight: CGFloat = 0
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

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
                ScrollViewReader { proxy in
                ScrollView {
                    rows(items)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { height in
                            // The scroll view's own height is derived from this measurement, so an
                            // unfiltered write can ping-pong between two heights and never settle.
                            guard abs(height - contentHeight) > 0.5 else { return }
                            contentHeight = height
                        }
                }
                .frame(height: min(max(contentHeight, 44), Self.maxHeight))
                // Applied outside the measured content on purpose: animating the content itself
                // reports a new height on every frame, which feeds the measurement above.
                .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.1), value: items.map(\.id))
                .onChange(of: ui.selected) { _, selected in
                    guard let selected else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { proxy.scrollTo(selected, anchor: .center) }
                }
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($listFocused)
        .onAppear { listFocused = true }
        .onChange(of: items.map(\.id)) { _, ids in ui.pruneSelection(to: ids) }
        .onKeyPress(.upArrow) { ui.moveSelection(-1, in: items.map(\.id)); return .handled }
        .onKeyPress(.downArrow) { ui.moveSelection(1, in: items.map(\.id)); return .handled }
        .onKeyPress(.rightArrow) { expandSelected(true) }
        .onKeyPress(.leftArrow) { expandSelected(false) }
        .onKeyPress(.space) { toggleSelected() }
        .onKeyPress(.return) { openSelected() }
    }

    // MARK: Keyboard

    private func expandSelected(_ expand: Bool) -> KeyPress.Result {
        guard let selected = ui.selected else { return .ignored }
        if expand { ui.expanded.insert(selected) } else { ui.expanded.remove(selected) }
        return .handled
    }

    private func toggleSelected() -> KeyPress.Result {
        guard let selected = ui.selected else { return .ignored }
        ui.toggle(selected)
        if ui.expanded.contains(selected), model.settings.markSeenOnExpand,
           let item = model.item(for: selected), item.unseen > 0 {
            model.markSeen(selected)
        }
        return .handled
    }

    private func openSelected() -> KeyPress.Result {
        guard let selected = ui.selected else { return .ignored }
        model.closePanel?()
        model.open(selected)
        return .handled
    }

    @ViewBuilder
    private func rows(_ items: [RepoItem]) -> some View {
        // A plain VStack on purpose. A LazyVStack sizes itself from the visible rect, which makes
        // the measured height depend on the scroll view's frame — and that frame comes from the
        // measurement, closing a layout feedback loop that spins the main thread forever.
        VStack(spacing: 1) {
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

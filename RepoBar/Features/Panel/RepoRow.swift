import SwiftUI
import GitEngine

struct RepoRow: View {
    let item: RepoItem
    @Environment(AppModel.self) private var model
    @Environment(PanelUIState.self) private var ui
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var isExpanded: Bool { ui.expanded.contains(item.id) }
    private var animation: Animation? { reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.12) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                expandedContent
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(hovering && !isExpanded ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
        .contextMenu { contextMenu }
        .accessibilityElement(children: .contain)
    }

    // MARK: Header row

    private var header: some View {
        Button {
            withAnimation(animation) { ui.toggle(item.id) }
            if ui.expanded.contains(item.id), model.settings.markSeenOnExpand, item.unseen > 0 {
                model.markSeen(item.id)
            }
        } label: {
            HStack(spacing: 10) {
                StatusDotView(item: item)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(item.name)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        if item.isDirty {
                            Circle().fill(.orange).frame(width: 6, height: 6)
                                .help("Uncommitted changes")
                        }
                    }
                    subtitle
                }
                Spacer(minLength: 6)
                counts
                if item.isChecking {
                    ProgressView().controlSize(.mini).frame(width: 12)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityIdentifier("repo-row-\(item.id.uuidString)")
        .accessibilityAddTraits(isExpanded ? [.isSelected] : [])
    }

    @ViewBuilder
    private var subtitle: some View {
        HStack(spacing: 6) {
            if let branch = item.branchLabel {
                Text(branch)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let error = item.error {
                Text(error.title)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            } else if let watched = item.watchedLabel, watched != "origin/\(item.branchLabel ?? "")" {
                Text("→ \(watched)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var counts: some View {
        HStack(spacing: 4) {
            if item.behind > 0 {
                CountCapsule(symbol: "arrow.down", count: item.behind, tint: item.unseen > 0 ? Color.accentColor : .secondary)
                    .help("\(item.behind) commits behind \(item.watchedLabel ?? "remote")")
            }
            if item.ahead > 0 {
                CountCapsule(symbol: "arrow.up", count: item.ahead, tint: .orange)
                    .help("\(item.ahead) unpushed commits")
            }
        }
    }

    private var accessibilityLabel: Text {
        var parts = [item.name]
        if let branch = item.branchLabel { parts.append("on \(branch)") }
        if item.unseen > 0 { parts.append("\(item.unseen) new commits") }
        else if item.behind > 0 { parts.append("\(item.behind) behind") }
        if item.ahead > 0 { parts.append("\(item.ahead) ahead") }
        if let error = item.error { parts.append(error.title) }
        return Text(parts.joined(separator: ", "))
    }

    // MARK: Expanded content

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = item.error {
                VStack(alignment: .leading, spacing: 3) {
                    Text(error.title).font(.caption.weight(.medium)).foregroundStyle(.red)
                    if let hint = error.hint {
                        Text(hint).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 10)
            }
            if let snapshot = item.snapshot {
                if !snapshot.incoming.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(snapshot.incoming.prefix(10)) { commit in
                            CommitRow(commit: commit, hasWebURL: snapshot.web != nil) {
                                model.openCommit(item.id, sha: commit.sha)
                            }
                        }
                        if snapshot.incoming.count > 10 {
                            Text("+\(snapshot.incoming.count - 10) more")
                                .font(.caption2).foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8).padding(.top, 2)
                        }
                    }
                    .padding(.horizontal, 4)
                } else if snapshot.error == nil {
                    Text(snapshot.watchedTipSHA == nil ? "Waiting for the first fetch…" : "Up to date with \(snapshot.watched?.key ?? "remote")")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                }
                if snapshot.isShallow {
                    Text("Shallow clone — the commit list may be incomplete").font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 10)
                }
                if snapshot.historyRewritten {
                    Text("Remote history was rewritten (force push)").font(.caption2).foregroundStyle(.orange).padding(.horizontal, 10)
                }
            }
            actionRow
        }
        .padding(.bottom, 8)
    }

    private var pullDisabledReason: String? {
        do {
            try PullService.preflight(snapshot: item.snapshot)
            return nil
        } catch {
            return error.message
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            let reason = pullDisabledReason
            Button("Pull") { model.pull(item.id) }
                .disabled(reason != nil)
                .help(reason ?? "Fast-forward the current branch (no merge commits)")
            if item.unseen > 0 {
                Button("Mark as seen") { model.markSeen(item.id) }
            }
            Spacer()
            openMenu
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.top, 2)
    }

    private var openMenu: some View {
        let activeApp = model.openApp(for: item.id)
        let installed = model.openApps
        return Menu {
            ForEach(ExternalApp.Kind.allCases, id: \.self) { kind in
                let apps = installed.filter { $0.kind == kind }
                if !apps.isEmpty {
                    Section(kind.title) {
                        ForEach(apps) { app in
                            Button {
                                model.closePanel?()
                                model.open(item.id, in: app)
                            } label: {
                                if app == activeApp {
                                    Label(app.name, systemImage: "checkmark")
                                } else {
                                    Text(app.name)
                                }
                            }
                        }
                    }
                }
            }
            if item.snapshot?.web != nil {
                Divider()
                Button("Repository page") { model.openRepositoryPage(item.id) }
            }
        } label: {
            Label("Open in \(activeApp.name)", systemImage: "arrow.up.forward.app")
        } primaryAction: {
            model.closePanel?()
            model.open(item.id, in: activeApp)
        }
        .fixedSize()
    }

    // MARK: Context menu

    @ViewBuilder
    private var contextMenu: some View {
        let installed = model.openApps
        ForEach(installed.filter { $0.kind == .finder || $0.kind == .terminal }) { app in
            Button("Open in \(app.name)") { model.closePanel?(); model.open(item.id, in: app) }
        }
        let editors = installed.filter { $0.kind != .finder && $0.kind != .terminal }
        if !editors.isEmpty {
            Menu("Open in…") {
                ForEach(editors) { app in
                    Button(app.name) { model.closePanel?(); model.open(item.id, in: app) }
                }
            }
        }
        Button("Copy Path") { model.copyPath(item.id) }
        Divider()
        Button("Check Now") { model.refresh(item.id) }
        if item.unseen > 0 {
            Button("Mark as Seen") { model.markSeen(item.id) }
        }
        Button("Pull (fast-forward)") { model.pull(item.id) }
            .disabled(pullDisabledReason != nil)
        Divider()
        Menu("Color") {
            ForEach(RepoColor.allCases, id: \.self) { color in
                Button {
                    model.setColor(item.id, color)
                } label: {
                    if color == item.color {
                        Label(color.displayName, systemImage: "checkmark")
                    } else {
                        Text(color.displayName)
                    }
                }
            }
        }
        Menu("Watch Branch") {
            Button {
                model.setWatch(item.id, .upstreamOfCurrentBranch)
            } label: {
                if case .upstreamOfCurrentBranch = item.record.watch { Label("Current branch (automatic)", systemImage: "checkmark") } else { Text("Current branch (automatic)") }
            }
            ForEach(WatchedRefResolver.heuristicBranches, id: \.self) { branch in
                Button {
                    model.setWatch(item.id, .remoteBranch(branch))
                } label: {
                    if case .remoteBranch(let current) = item.record.watch, current == branch { Label(branch, systemImage: "checkmark") } else { Text(branch) }
                }
            }
            if case .remoteBranch(let current) = item.record.watch, !WatchedRefResolver.heuristicBranches.contains(current) {
                Label(current, systemImage: "checkmark")
            }
        }
        Toggle("Mute Notifications", isOn: Binding(
            get: { item.record.notificationsMuted },
            set: { model.setMuted(item.id, $0) }
        ))
        Divider()
        Button("Remove…", role: .destructive) {
            withAnimation(animation) { ui.confirmingRemoval = item.id }
        }
    }
}

struct CountCapsule: View {
    let symbol: String
    let count: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            Text("\(count)").font(.caption.weight(.semibold)).monospacedDigit()
                .contentTransition(.numericText())
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        // The popover is translucent, so a tint-only wash disappears over a dark
        // wallpaper. An opaque base gives the capsule a ground of its own.
        .background {
            Capsule()
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(Capsule().fill(tint.opacity(0.20)))
                .overlay(Capsule().strokeBorder(tint.opacity(0.40), lineWidth: 0.5))
        }
    }
}

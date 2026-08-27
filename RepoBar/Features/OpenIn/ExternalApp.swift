import AppKit

/// An application a repository folder can be opened in. Only installed apps are offered.
nonisolated struct ExternalApp: Identifiable, Hashable, Sendable {
    /// The order also groups the menus: the cases are walked in order and each one that has
    /// an installed application becomes its own block between dividers.
    enum Kind: String, CaseIterable, Sendable {
        case finder, custom, terminal, editor, gitClient
    }

    /// Bundle identifier.
    let id: String
    let name: String
    let kind: Kind

    static let finder = ExternalApp(id: "com.apple.finder", name: "Finder", kind: .finder)

    static let catalog: [ExternalApp] = [
        finder,
        ExternalApp(id: "com.apple.Terminal", name: "Terminal", kind: .terminal),
        ExternalApp(id: "com.googlecode.iterm2", name: "iTerm", kind: .terminal),
        ExternalApp(id: "dev.warp.Warp-Stable", name: "Warp", kind: .terminal),
        ExternalApp(id: "com.mitchellh.ghostty", name: "Ghostty", kind: .terminal),
        ExternalApp(id: "com.microsoft.VSCode", name: "Visual Studio Code", kind: .editor),
        ExternalApp(id: "com.todesktop.230313mzl4w4u92", name: "Cursor", kind: .editor),
        ExternalApp(id: "dev.zed.Zed", name: "Zed", kind: .editor),
        ExternalApp(id: "com.apple.dt.Xcode", name: "Xcode", kind: .editor),
        ExternalApp(id: "com.sublimetext.4", name: "Sublime Text", kind: .editor),
        ExternalApp(id: "com.panic.Nova", name: "Nova", kind: .editor),
        ExternalApp(id: "com.barebones.bbedit", name: "BBEdit", kind: .editor),
        ExternalApp(id: "com.google.antigravity", name: "Antigravity", kind: .editor),
        ExternalApp(id: "com.DanPristupov.Fork", name: "Fork", kind: .gitClient),
        ExternalApp(id: "com.fournova.Tower3", name: "Tower", kind: .gitClient),
        ExternalApp(id: "com.github.GitHubClient", name: "GitHub Desktop", kind: .gitClient),
        ExternalApp(id: "com.torusknot.SourceTreeNotMAS", name: "Sourcetree", kind: .gitClient),
        ExternalApp(id: "com.sublimemerge", name: "Sublime Merge", kind: .gitClient),
    ]
}

nonisolated enum ExternalAppCatalog {
    /// Catalog entries whose application is installed. `isInstalled` is injectable for tests.
    static func installed(isInstalled: (String) -> Bool = { ExternalAppCatalog.applicationURL(for: $0) != nil }) -> [ExternalApp] {
        ExternalApp.catalog.filter { $0.kind == .finder || isInstalled($0.id) }
    }

    static func applicationURL(for bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func app(withID id: String) -> ExternalApp? {
        ExternalApp.catalog.first { $0.id == id }
    }

    /// An app the user picked by hand. The name is read from the bundle on disk, so
    /// the entry disappears from the list once the app is deleted.
    static func customApp(bundleID: String) -> ExternalApp? {
        guard let url = applicationURL(for: bundleID) else { return nil }
        return ExternalApp(id: bundleID, name: url.deletingPathExtension().lastPathComponent, kind: .custom)
    }
}

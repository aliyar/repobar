import AppKit
import OSLog

enum OpenInService {
    /// Opens a folder in the given app (Finder shows the folder; other apps get it like a Dock drop).
    static func open(_ folder: URL, in app: ExternalApp) {
        if app.kind == .finder {
            NSWorkspace.shared.open(folder)
            return
        }
        guard let appURL = ExternalAppCatalog.applicationURL(for: app.id) else {
            NSWorkspace.shared.open(folder)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([folder], withApplicationAt: appURL, configuration: configuration) { _, error in
            if let error { Log.ui.error("open in \(app.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    static func icon(for app: ExternalApp) -> NSImage? {
        guard let url = ExternalAppCatalog.applicationURL(for: app.id) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }
}

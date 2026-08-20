import AppKit
import OSLog

enum AppActivation {
    /// Cooperative activation (macOS 14+). Falls back to the legacy forceful variant when the
    /// cooperative request is refused, which happens for accessory apps that were not the
    /// last-interacted app (e.g. when a notification action or a menu bar click triggers us).
    static func activate() {
        NSApp.activate()
        if !NSApp.isActive {
            // Legacy forceful activation. Deprecated in macOS 14 ("may have no effect"), but it is
            // still what makes an accessory app's window come forward after a status-item click
            // on macOS 14–26 (verified), so it is called through a selector to avoid the warning.
            let selector = NSSelectorFromString("activateIgnoringOtherApps:")
            if NSApp.responds(to: selector) {
                NSApp.perform(selector, with: true)
            }
        }
    }

    /// Opens the SwiftUI `Settings` scene and makes sure it is in front of other apps' windows.
    static func openSettings() {
        activate()
        let opened = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        Log.ui.notice("showSettingsWindow: sent, handled=\(opened)")
        bringSettingsToFront()
    }

    static func bringSettingsToFront() {
        Task { @MainActor in
            for attempt in 0..<15 {
                if let window = NSApp.windows.first(where: isSettingsWindow) {
                    activate()
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                    Log.ui.notice("settings window fronted after \(attempt) attempts; active=\(NSApp.isActive) id=\(window.identifier?.rawValue ?? "-", privacy: .public)")
                    // Activation can land a tick later; re-assert once.
                    try? await Task.sleep(for: .milliseconds(120))
                    if !NSApp.isActive { activate(); window.makeKeyAndOrderFront(nil) }
                    Log.ui.notice("settings window re-asserted; active=\(NSApp.isActive)")
                    return
                }
                try? await Task.sleep(for: .milliseconds(40))
            }
            let summary = NSApp.windows.map { "[\($0.identifier?.rawValue ?? "-") | \($0.title) | \(type(of: $0))]" }.joined(separator: " ")
            Log.ui.notice("settings window not found; windows: \(summary, privacy: .public)")
        }
    }

    /// SwiftUI's Settings scene window: identifier "com_apple_SwiftUI_Settings_window" (macOS 13–15),
    /// falling back to title/class heuristics.
    static func isSettingsWindow(_ window: NSWindow) -> Bool {
        if let id = window.identifier?.rawValue.lowercased(), id.contains("settings") || id.contains("preferences") { return true }
        if window.title.localizedCaseInsensitiveContains("settings") { return true }
        return String(describing: type(of: window)).lowercased().contains("settings")
    }
}

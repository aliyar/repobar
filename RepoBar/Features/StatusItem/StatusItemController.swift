import AppKit
import SwiftUI
import OSLog

/// Owns the `NSStatusItem` and the `NSPopover` that hosts the SwiftUI panel.
/// All public API is main-actor; AppKit callbacks hop back onto the main actor explicitly.
final class StatusItemController: NSObject, NSPopoverDelegate {
    // MARK: Inputs
    var state = MenuBarState() {
        didSet { if state != oldValue { render() } }
    }
    /// Builds the SwiftUI root of the popover. Set before `install()`.
    var panelRoot: (() -> AnyView)?

    // MARK: Callbacks (wired by AppDependencies)
    var onRefreshAll: (() -> Void)?
    var onMarkAllSeen: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?
    var onPanelOpened: (() -> Void)?
    var onPanelClosed: (() -> Void)?
    var onInstallUpdate: (() -> Void)?
    /// Version string of an available app update (adds an item to the context menu).
    var updateAvailableVersion: String?
    /// nil → follow the system. Applied to the popover only, so the status item glyph
    /// keeps matching the menu bar rather than the app's chosen theme.
    var appearance: NSAppearance? {
        didSet { popover.appearance = appearance }
    }

    // MARK: Private
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let renderer = StatusItemRenderer()
    private var appearanceObservation: NSKeyValueObservation?
    private var lastRendered: (layout: StatusItemLayout, dark: Bool, scale: CGFloat)?
    private var renderPending = false
    private var globalMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var activateObserver: NSObjectProtocol?

    var isPopoverShown: Bool { popover.isShown }

    // MARK: Lifecycle

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.behavior = []
        statusItem = item

        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.render() }
            }
        }

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let host = NSHostingController(rootView: panelRoot?() ?? AnyView(EmptyView()))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        render()
        Log.statusItem.info("status item installed")
    }

    /// Re-renders the status item image. Replacing the button image while the popover is shown makes
    /// AppKit dismiss the popover, so visual changes are deferred until it closes; non-visual state
    /// changes (e.g. "checking") never touch the image at all.
    func render() {
        guard let button = statusItem?.button else { return }
        if button.toolTip != state.summary {
            button.toolTip = state.summary
            button.setAccessibilityLabel(state.summary)
        }
        let layout = StatusItemLayout.make(from: state)
        let scale = button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if let last = lastRendered, last.layout == layout, last.dark == dark, last.scale == scale { return }
        if popover.isShown {
            renderPending = true
            return
        }
        let image = renderer.image(for: layout, appearance: button.effectiveAppearance, scale: scale)
        button.image = image
        lastRendered = (layout, dark, scale)
        renderPending = false
        dumpIfRequested(image, layout: layout)
    }

    /// Debug aid: `REPOBAR_DUMP_STATUS_IMAGE=/path/prefix` writes light+dark renders as PNG.
    private func dumpIfRequested(_ image: NSImage?, layout: StatusItemLayout) {
        guard let prefix = ProcessInfo.processInfo.environment["REPOBAR_DUMP_STATUS_IMAGE"] else { return }
        for (name, appearance) in [("light", NSAppearance(named: .aqua)!), ("dark", NSAppearance(named: .darkAqua)!)] {
            guard let img = renderer.image(for: layout, appearance: appearance, scale: 2),
                  let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: URL(fileURLWithPath: "\(prefix)-\(name).png"))
        }
        if let image { Log.statusItem.debug("status image size \(image.size.width)x\(image.size.height)") }
    }

    // MARK: Popover

    func showPopover() {
        guard let button = statusItem?.button, !popover.isShown else { return }
        AppActivation.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        button.highlight(true)
        installMonitors()
        if !NSApp.isActive { makePopoverKeyWhenActive() }
        Log.statusItem.debug("popover shown; appActive=\(NSApp.isActive)")
        onPanelOpened?()
    }

    func closePopover() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    func togglePopover() {
        popover.isShown ? closePopover() : showPopover()
    }

    func popoverDidClose(_ notification: Notification) {
        Log.statusItem.debug("popover closed")
        statusItem?.button?.highlight(false)
        removeMonitors()
        onPanelClosed?()
        if renderPending { render() }
    }

    private func installMonitors() {
        removeMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in self?.closePopover() }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        globalMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        if let activateObserver { NotificationCenter.default.removeObserver(activateObserver) }
        activateObserver = nil
    }

    /// Activation is asynchronous; once the app becomes active make the popover key so that
    /// keyboard shortcuts inside the panel work immediately.
    private func makePopoverKeyWhenActive() {
        activateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.popover.isShown else { return }
                self.popover.contentViewController?.view.window?.makeKey()
            }
        }
    }

    // MARK: Clicks & menu

    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp || (event?.modifierFlags.contains(.control) ?? false)
        if isSecondary {
            closePopover()
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func showMenu() {
        guard let item = statusItem else { return }
        let menu = NSMenu()
        if let version = updateAvailableVersion {
            menu.addItem(makeItem("Install RepoBar \(version)…", action: #selector(menuInstallUpdate), key: ""))
            menu.addItem(.separator())
        }
        menu.addItem(makeItem("Refresh All", action: #selector(menuRefreshAll), key: "r"))
        menu.addItem(makeItem("Mark All as Seen", action: #selector(menuMarkAllSeen), key: ""))
        menu.addItem(makeItem(state.isPaused ? "Resume Checks" : "Pause Checks", action: #selector(menuTogglePause), key: ""))
        menu.addItem(.separator())
        menu.addItem(makeItem("Settings…", action: #selector(menuOpenSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit RepoBar", action: #selector(menuQuit), key: "q"))
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func makeItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func menuRefreshAll() { onRefreshAll?() }
    @objc private func menuMarkAllSeen() { onMarkAllSeen?() }
    @objc private func menuTogglePause() { onTogglePause?() }
    @objc private func menuOpenSettings() { onOpenSettings?() }
    @objc private func menuQuit() { onQuit?() }
    @objc private func menuInstallUpdate() { onInstallUpdate?() }
}

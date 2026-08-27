import AppKit
import SwiftUI
import Testing
import GitEngine
@testable import RepoBar

/// Renders the README screenshots from the real SwiftUI views with sample data.
/// Runs only when `make screenshots` points at an output directory (env var or marker file).
@Suite("Screenshots")
struct ScreenshotTests {
    nonisolated static let outputDirectory: URL? = {
        if let env = ProcessInfo.processInfo.environment["REPOBAR_SCREENSHOT_DIR"] {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        // xcodebuild does not forward environment variables to hosted tests; the Makefile writes a marker.
        let marker = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/screenshot-dir")
        guard let path = try? String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }()

    @Test(.enabled(if: outputDirectory != nil))
    func renderReadmeScreenshots() throws {
        let directory = try #require(Self.outputDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scene = ScreenshotScene()

        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            try write(scene.hero(scheme), name: "hero-\(suffix).jpg", to: directory, format: .jpeg)
            try write(scene.panel(scheme), name: "panel-\(suffix).png", to: directory)
            try write(scene.menuBarStyles(scheme), name: "menubar-styles-\(suffix).png", to: directory)
            try write(scene.settings(scheme), name: "settings-\(suffix).png", to: directory)
            // Web assets: the panel with no canvas and no baked shadow, so the page owns elevation.
            try write(scene.panelBare(scheme), name: "panel-bare-\(suffix).png", to: directory)
            try write(scene.settingsBare(scheme), name: "settings-bare-\(suffix).png", to: directory)
        }
        try write(scene.openGraph(), name: "og.png", to: directory, scale: 1)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("hero-light.jpg").path))
    }

    /// Renders through a real (offscreen) window so AppKit-backed controls — pickers, toggles, menus,
    /// SettingsLink — draw like they do on screen. `ImageRenderer` cannot draw those.
    private func write(_ view: some View, name: String, to directory: URL, scale: CGFloat = 2, format: NSBitmapImageRep.FileType = .png) throws {
        // The offscreen window is never key; tell SwiftUI to draw controls in their active state anyway.
        let hosting = NSHostingView(rootView: view.environment(\.controlActiveState, .key))
        hosting.sizingOptions = [.intrinsicContentSize]
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hosting
        pumpRunLoop()
        // Size the window to the laid-out content (the first measurement happens before SwiftUI's layout).
        for _ in 0..<2 {
            let size = hosting.fittingSize
            window.setContentSize(size)
            hosting.frame = NSRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded()
            pumpRunLoop()
        }
        let bounds = hosting.bounds
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = bounds.size
        hosting.cacheDisplay(in: bounds, to: rep)
        let properties: [NSBitmapImageRep.PropertyKey: Any] = format == .jpeg ? [.compressionFactor: 0.9] : [:]
        let data = try #require(rep.representation(using: format, properties: properties))
        try data.write(to: directory.appendingPathComponent(name))
        window.contentView = nil
    }

    private func pumpRunLoop() {
        for _ in 0..<3 { RunLoop.main.run(until: Date().addingTimeInterval(0.04)) }
    }
}

// MARK: - Scene

struct ScreenshotScene {
    let model: AppModel
    let ui = PanelUIState()
    let updates = UpdateController()
    let loginItem = LoginItemController()
    let notifications = NotificationManager()

    init() {
        model = AppModel.preview()
        if let website = model.records.first(where: { $0.name == "website" }) {
            ui.expanded.insert(website.id)
        }
    }

    // Canvas colors (explicit RGB: NSColor dynamic colors don't follow the SwiftUI color scheme offscreen).
    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.11, green: 0.11, blue: 0.12) : Color(red: 0.93, green: 0.93, blue: 0.94)
    }

    static func popoverBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.16, green: 0.16, blue: 0.17) : Color(red: 0.98, green: 0.98, blue: 0.98)
    }

    static func wallpaper(_ scheme: ColorScheme) -> LinearGradient {
        if scheme == .dark {
            return LinearGradient(colors: [Color(red: 0.09, green: 0.11, blue: 0.26), Color(red: 0.24, green: 0.12, blue: 0.36), Color(red: 0.05, green: 0.05, blue: 0.11)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        return LinearGradient(colors: [Color(red: 0.55, green: 0.73, blue: 0.98), Color(red: 0.84, green: 0.76, blue: 0.98), Color(red: 0.99, green: 0.86, blue: 0.80)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    func panelView(_ scheme: ColorScheme) -> some View {
        MenuBarPanel()
            .environment(model)
            .environment(ui)
            .environment(updates)
            .environment(\.staticLayout, true)
            .environment(\.colorScheme, scheme)
            .background(Self.popoverBackground(scheme))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    func panel(_ scheme: ColorScheme) -> some View {
        panelView(scheme)
            .shadow(color: .black.opacity(scheme == .dark ? 0.6 : 0.22), radius: 22, y: 10)
            .padding(44)
            .background(Self.canvas(scheme))
    }

    func hero(_ scheme: ColorScheme) -> some View {
        let layout = StatusItemLayout.make(from: model.menuBar)
        return ZStack(alignment: .top) {
            Self.wallpaper(scheme)
            VStack(spacing: 0) {
                MenuBarStrip(layout: layout, scheme: scheme, highlighted: true)
                HStack {
                    Spacer()
                    VStack(spacing: 0) {
                        PopoverArrow().fill(Self.popoverBackground(scheme)).frame(width: 22, height: 11)
                        panelView(scheme)
                    }
                    .shadow(color: .black.opacity(scheme == .dark ? 0.55 : 0.28), radius: 28, y: 14)
                    .padding(.trailing, MenuBarStrip.statusItemCenterFromTrailing - MenuBarPanel.width / 2)
                }
                .padding(.top, 6)
            }
        }
        .frame(width: 780, height: 540)
        .environment(\.colorScheme, scheme)
    }

    /// The panel alone, transparent, no shadow — the page applies its own elevation.
    func panelBare(_ scheme: ColorScheme) -> some View {
        panelView(scheme)
            .padding(6)
            .environment(\.colorScheme, scheme)
    }

    /// The Settings window with no canvas and no baked shadow.
    func settingsBare(_ scheme: ColorScheme) -> some View {
        WindowFrame(title: "General", tabs: ["General", "Advanced", "About"], icons: ["gearshape", "wrench.and.screwdriver", "info.circle"], selected: 0, scheme: scheme) {
            GeneralSettingsView()
                .environment(model)
                .environment(loginItem)
                .environment(notifications)
                .environment(updates)
                .frame(width: 480)
        }
        .padding(6)
        .environment(\.colorScheme, scheme)
    }

    /// 1200x630 social card, rendered from the same components the app ships.
    func openGraph() -> some View {
        let layout = StatusItemLayout.make(from: model.menuBar)
        return ZStack {
            LinearGradient(colors: [Color(red: 0.44, green: 0.52, blue: 0.93), Color(red: 0.15, green: 0.23, blue: 0.53)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                MenuBarStrip(layout: layout, scheme: .light, highlighted: false, width: 300, showsAppMenu: false, opaque: true)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .scaleEffect(2.1, anchor: .topLeading)
                    .frame(width: 630, height: 50, alignment: .topLeading)
                    .shadow(color: .black.opacity(0.3), radius: 26, y: 12)
                Text("RepoBar")
                    .font(.system(size: 76, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.top, 40)
                Text("Know which repositories have new commits — without clicking.")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(2)
                    .padding(.top, 12)
                Spacer(minLength: 0)
                Text("repobar.greatpixels.com")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
            }
            .padding(72)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 1200, height: 630)
        .environment(\.colorScheme, .dark)
    }

    func menuBarStyles(_ scheme: ColorScheme) -> some View {
        let base = model.menuBar
        let variants: [(String, String, MenuBarState)] = [
            ("Dots", "One dot per repository — filled when the remote has new commits, a hollow ring when idle, ring + ! on errors.", { var s = base; s.style = .dots; return s }()),
            ("Count", "The number of repositories (or commits) with new commits.", { var s = base; s.style = .count; return s }()),
            ("Icon only", "Just the glyph, with an accent dot when something is new.", { var s = base; s.style = .iconOnly; return s }()),
        ]
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Color.clear.frame(width: 240, height: 1)
                Text("Light menu bar").frame(width: 300)
                Text("Dark menu bar").frame(width: 300)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)

            ForEach(Array(variants.enumerated()), id: \.offset) { _, variant in
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(variant.0).font(.system(size: 15, weight: .semibold))
                        Text(variant.1).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .frame(width: 240, alignment: .leading)
                    strip(for: variant.2, scheme: .light)
                    strip(for: variant.2, scheme: .dark)
                }
            }
        }
        .padding(32)
        .background(Self.canvas(scheme))
        .environment(\.colorScheme, scheme)
    }

    /// One menu bar strip in a fixed theme, so a single image can show both.
    private func strip(for state: MenuBarState, scheme: ColorScheme) -> some View {
        MenuBarStrip(layout: StatusItemLayout.make(from: state), scheme: scheme, highlighted: false, width: 300, showsAppMenu: false, opaque: true)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
    }

    func settings(_ scheme: ColorScheme) -> some View {
        WindowFrame(title: "General", tabs: ["General", "Advanced", "About"], icons: ["gearshape", "wrench.and.screwdriver", "info.circle"], selected: 0, scheme: scheme) {
            GeneralSettingsView()
                .environment(model)
                .environment(loginItem)
                .environment(notifications)
                .environment(updates)
                .frame(width: 480)
        }
        .shadow(color: .black.opacity(scheme == .dark ? 0.6 : 0.22), radius: 22, y: 10)
        .padding(44)
        .background(Self.canvas(scheme))
        .environment(\.colorScheme, scheme)
    }
}

// MARK: - Mock chrome

/// A macOS-like menu bar strip hosting the real status item rendering.
struct MenuBarStrip: View {
    let layout: StatusItemLayout
    let scheme: ColorScheme
    var highlighted: Bool
    var width: CGFloat = 780
    var showsAppMenu = true
    /// Standalone strips (no wallpaper behind them) need a solid menu bar color.
    var opaque = false

    static let statusItemWidth: CGFloat = 96
    /// Distance from the strip's trailing edge to the status item's center (keeps the hero arrow aligned).
    static let statusItemCenterFromTrailing: CGFloat = 16 + 64 + 14 + 24 + 14 + 18 + 14 + statusItemWidth / 2

    private var foreground: Color { scheme == .dark ? .white.opacity(0.92) : .black.opacity(0.85) }

    private var background: Color {
        if opaque { return scheme == .dark ? Color(white: 0.14) : Color(white: 0.97) }
        return scheme == .dark ? Color.black.opacity(0.38) : Color.white.opacity(0.55)
    }

    var body: some View {
        HStack(spacing: 0) {
            if showsAppMenu {
                HStack(spacing: 18) {
                    Image(systemName: "apple.logo").font(.system(size: 14))
                    Text("Finder").fontWeight(.bold)
                    Text("File")
                    Text("Edit")
                    Text("View")
                    Text("Go")
                    Text("Window")
                    Text("Help")
                }
                .padding(.leading, 18)
            }
            Spacer()
            StatusItemView(layout: layout, foreground: foreground)
                .frame(width: Self.statusItemWidth, height: 22)
                .background(highlighted ? Color.primary.opacity(scheme == .dark ? 0.22 : 0.14) : .clear, in: RoundedRectangle(cornerRadius: 4))
            Spacer().frame(width: 14)
            Image(systemName: "wifi").frame(width: 18)
            Spacer().frame(width: 14)
            Image(systemName: "battery.100percent").frame(width: 24)
            Spacer().frame(width: 14)
            Text("Mon 9:41").frame(width: 64, alignment: .trailing)
            Spacer().frame(width: 16)
        }
        .font(.system(size: 13))
        .foregroundStyle(foreground)
        .frame(width: width, height: 24)
        .background(background)
    }
}

struct PopoverArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Settings-window chrome: traffic lights + toolbar tabs.
struct WindowFrame<Content: View>: View {
    let title: String
    let tabs: [String]
    let icons: [String]
    let selected: Int
    let scheme: ColorScheme
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 8) {
                    Circle().fill(Color(red: 1.0, green: 0.38, blue: 0.35))
                    Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18))
                    Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.26))
                }
                .frame(width: 52, height: 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 14)
                HStack(spacing: 6) {
                    ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                        VStack(spacing: 3) {
                            Image(systemName: icons[index]).font(.system(size: 19))
                            Text(tab).font(.system(size: 11))
                        }
                        .frame(width: 64, height: 50)
                        .foregroundStyle(index == selected ? Color.accentColor : .secondary)
                        .background(index == selected ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .frame(height: 64)
            .background(scheme == .dark ? Color(red: 0.20, green: 0.20, blue: 0.21) : Color(red: 0.96, green: 0.96, blue: 0.96))
            Divider()
            content
                .background(scheme == .dark ? Color(red: 0.13, green: 0.13, blue: 0.14) : Color(red: 0.94, green: 0.94, blue: 0.95))
        }
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

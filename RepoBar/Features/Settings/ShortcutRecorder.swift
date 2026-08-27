import AppKit
import SwiftUI
import Carbon.HIToolbox

/// A field that captures one key combination. Click it, press the keys, done.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: GlobalHotKey.Shortcut?

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onCapture = { shortcut = $0 }
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.shortcut = shortcut
    }

    final class RecorderView: NSView {
        var onCapture: ((GlobalHotKey.Shortcut?) -> Void)?
        var shortcut: GlobalHotKey.Shortcut? { didSet { needsDisplay = true } }
        private var recording = false { didSet { needsDisplay = true } }

        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: 116, height: 22) }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            recording = true
        }

        override func resignFirstResponder() -> Bool {
            recording = false
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard recording else { return super.keyDown(with: event) }
            if event.keyCode == UInt16(kVK_Escape) {
                recording = false
                window?.makeFirstResponder(nil)
                return
            }
            if event.keyCode == UInt16(kVK_Delete) {
                shortcut = nil
                onCapture?(nil)
                recording = false
                window?.makeFirstResponder(nil)
                return
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .intersection([.command, .option, .control, .shift])
            let candidate = GlobalHotKey.Shortcut(keyCode: UInt32(event.keyCode), modifiers: flags.rawValue)
            // Without command/option/control this would eat plain typing everywhere.
            guard candidate.isValid else { NSSound.beep(); return }
            shortcut = candidate
            onCapture?(candidate)
            recording = false
            window?.makeFirstResponder(nil)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard recording else { return false }
            keyDown(with: event)
            return true
        }

        override func draw(_ dirtyRect: NSRect) {
            let rounded = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            (recording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
            rounded.fill()
            (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            rounded.lineWidth = recording ? 1.5 : 1
            rounded.stroke()

            let text = recording ? "Press keys…" : (shortcut?.displayString ?? "Click to set")
            let dimmed = recording || shortcut == nil
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: shortcut == nil ? .regular : .medium),
                .foregroundColor: dimmed ? NSColor.secondaryLabelColor : NSColor.labelColor,
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
        }
    }
}

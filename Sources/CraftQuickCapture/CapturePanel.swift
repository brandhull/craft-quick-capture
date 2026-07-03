import AppKit
import SwiftUI

/// Borderless floating panel that can take keyboard focus.
final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CapturePanelController {
    private var panel: CapturePanel?
    private var keyMonitor: Any?
    let model: CaptureModel

    init(store: DocumentStore) {
        self.model = CaptureModel(store: store)
        self.model.onClose = { [weak self] in self?.hide() }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        let panel = ensurePanel()
        model.prepareForShow()
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installKeyMonitor()
    }

    func hide() {
        removeKeyMonitor()
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> CapturePanel {
        if let panel { return panel }
        let panel = CapturePanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 240),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow

        let host = NSHostingView(rootView: CaptureView(model: model))
        host.sizingOptions = [.preferredContentSize]
        panel.contentView = host

        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        panel.layoutIfNeeded()
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let x = frame.midX - size.width / 2
        let y = frame.maxY - frame.height * 0.28 - size.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Handles esc / ⌘↩ / arrows / ⌘V-with-image before the field editor sees them.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            let cmd = event.modifierFlags.contains(.command)

            switch event.keyCode {
            case 53: // esc
                if self.model.isPickingDoc {
                    self.model.isPickingDoc = false
                    self.model.docQuery = ""
                } else {
                    self.hide()
                }
                return nil
            case 36 where cmd: // ⌘↩
                self.model.save()
                return nil
            case 36 where self.model.isPickingDoc: // ↩ picks highlighted doc
                self.model.chooseHighlighted()
                return nil
            case 125 where self.model.isPickingDoc: // ↓
                self.model.moveHighlight(1)
                return nil
            case 126 where self.model.isPickingDoc: // ↑
                self.model.moveHighlight(-1)
                return nil
            case 9 where cmd: // ⌘V — intercept only when the pasteboard holds an image
                if self.model.pasteImageIfPresent() { return nil }
                return event
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

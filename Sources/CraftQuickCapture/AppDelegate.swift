import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var store: DocumentStore!
    private var panelController: CapturePanelController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = DocumentStore()
        panelController = CapturePanelController(store: store)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "CraftQuickCapture" // persist ⌘-drag position across launches
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "square.and.pencil",
                                   accessibilityDescription: "Craft Quick Capture")
        }
        statusItem.menu = buildMenu()

        hotKey = HotKey { [weak self] in
            self?.panelController.toggle()
        }
        if hotKey == nil {
            NSLog("CraftQuickCapture: failed to register ⌥⌘Space (another app may own it)")
        }

        if !Config.isConfigured {
            promptForCraftLink(firstRun: true)
        }
    }

    private func promptForCraftLink(firstRun: Bool) {
        let alert = NSAlert()
        alert.messageText = firstRun ? "Connect to Craft" : "Set Craft Connection"
        alert.informativeText = """
        Paste your Craft MCP link (looks like https://mcp.craft.do/links/…/mcp).

        In Craft: create an AI connection link for your space — Craft's AI/Imagine \
        settings offer a shareable MCP link. Anyone with this link can read and \
        write your Craft space, so treat it like a password.
        """
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = "https://mcp.craft.do/links/…/mcp"
        field.stringValue = firstRun ? "" : Config.load().mcpUrl
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let url = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, URL(string: url) != nil else { return }
        Config(mcpUrl: url).save()
        store.refresh()
    }

    @objc private func setCraftConnection() {
        promptForCraftLink(firstRun: false)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let capture = NSMenuItem(title: "Quick Capture", action: #selector(openCapture), keyEquivalent: " ")
        capture.keyEquivalentModifierMask = [.command, .option]
        capture.target = self
        menu.addItem(capture)

        let refresh = NSMenuItem(title: "Refresh Documents", action: #selector(refreshDocs), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)

        let connection = NSMenuItem(title: "Set Craft Connection…", action: #selector(setCraftConnection), keyEquivalent: "")
        connection.target = self
        menu.addItem(connection)

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Craft Quick Capture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        return menu
    }

    @objc private func openCapture() {
        panelController.show()
    }

    @objc private func refreshDocs() {
        store.refresh()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                sender.state = .off
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
            }
        } catch {
            NSLog("CraftQuickCapture: launch-at-login toggle failed: \(error.localizedDescription)")
        }
    }
}

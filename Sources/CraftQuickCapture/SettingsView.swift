import AppKit
import Carbon.HIToolbox
import SwiftUI

struct SettingsView: View {
    @State private var spec: HotKeySpec
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var message: String?
    @State private var newLink = ""
    @ObservedObject var store: DocumentStore

    /// Applies the new shortcut; returns false if it couldn't be registered.
    let onApply: (HotKeySpec) -> Bool
    /// Persists the new connection list and kicks off a refresh.
    let onConnectionsChanged: ([String]) -> Void

    init(spec: HotKeySpec, store: DocumentStore,
         onApply: @escaping (HotKeySpec) -> Bool,
         onConnectionsChanged: @escaping ([String]) -> Void) {
        _spec = State(initialValue: spec)
        self.store = store
        self.onApply = onApply
        self.onConnectionsChanged = onConnectionsChanged
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Capture shortcut")
                Spacer()
                Button(action: toggleRecording) {
                    Text(isRecording ? "Type shortcut…" : spec.display)
                        .frame(minWidth: 110)
                }
                .keyboardShortcut(.none)
            }
            Text(message ?? "Click the shortcut, then press the new key combo. Include ⌘, ⌥, or ⌃.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Reset to Default") { apply(.default) }
                    .disabled(spec == .default)
                Spacer()
            }
            Divider()
            spacesSection
        }
        .padding(20)
        .frame(width: 420)
        .onDisappear { stopRecording() }
    }

    private var connections: [String] { Config.load().effectiveConnections }

    private var spacesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Craft spaces")
                .font(.system(size: 13, weight: .medium))
            ForEach(Array(connections.enumerated()), id: \.offset) { index, url in
                HStack {
                    Text(store.spaceNames[url]
                         ?? (connections.count > 1 ? "Space \(index + 1)" : "Your space"))
                        .font(.system(size: 12))
                    if index == 0 && connections.count > 1 {
                        Text("primary")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text("…" + url.suffix(18))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                    Button("Remove") {
                        var urls = connections
                        urls.remove(at: index)
                        onConnectionsChanged(urls)
                    }
                    .disabled(connections.count == 1)
                }
            }
            HStack {
                TextField("Paste another space's MCP link…", text: $newLink)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                Button("Add") {
                    let url = newLink.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !url.isEmpty, URL(string: url) != nil,
                          !connections.contains(url) else { return }
                    onConnectionsChanged(connections + [url])
                    newLink = ""
                }
                .disabled(newLink.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Each Craft space has its own MCP link (created in that space's AI settings). Daily-note captures go to the primary space.")
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        message = "Press the new shortcut (esc cancels)…"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // esc
                stopRecording()
                message = nil
                return nil
            }
            let mods = HotKeySpec.carbonModifiers(from: event.modifierFlags)
            let required = UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey)
            guard mods & required != 0 else {
                message = "Include at least one of ⌘, ⌥, or ⌃."
                return nil
            }
            let newSpec = HotKeySpec.from(event: event)
            stopRecording()
            apply(newSpec)
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func apply(_ newSpec: HotKeySpec) {
        if onApply(newSpec) {
            spec = newSpec
            message = nil
        } else {
            message = "Couldn't register \(newSpec.display) — another app may own it."
        }
    }
}

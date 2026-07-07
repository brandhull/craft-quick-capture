import AppKit
import Carbon.HIToolbox
import SwiftUI

struct SettingsView: View {
    @State private var spec: HotKeySpec
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var message: String?

    /// Applies the new shortcut; returns false if it couldn't be registered.
    let onApply: (HotKeySpec) -> Bool

    init(spec: HotKeySpec, onApply: @escaping (HotKeySpec) -> Bool) {
        _spec = State(initialValue: spec)
        self.onApply = onApply
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
        }
        .padding(20)
        .frame(width: 360)
        .onDisappear { stopRecording() }
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

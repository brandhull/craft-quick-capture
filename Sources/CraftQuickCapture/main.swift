import AppKit

// Hidden diagnostic: `CraftQuickCapture --selftest <pageId> [imagePath]`
// exercises the exact save pipeline (image relay + append) and exits.
if let idx = CommandLine.arguments.firstIndex(of: "--selftest"),
   CommandLine.arguments.count > idx + 1 {
    let pageId = CommandLine.arguments[idx + 1]
    let imagePath = CommandLine.arguments.count > idx + 2 ? CommandLine.arguments[idx + 2] : nil
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            let client = CraftClient()
            var markdown = "## Selftest heading\n\nSelf-test capture \(Date())\nsoft-break line\n\n- [ ] selftest task"
            if let imagePath {
                let data = try Data(contentsOf: URL(fileURLWithPath: imagePath))
                let url = try await ImageUploader.upload(data, filename: "selftest.png")
                print("uploaded image: \(url)")
                markdown += "\n\n![image](\(url))"
            }
            try await client.appendBlocks(pageId: pageId, markdown: markdown)
            print("selftest OK")
        } catch {
            print("selftest FAILED: \(error.localizedDescription)")
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

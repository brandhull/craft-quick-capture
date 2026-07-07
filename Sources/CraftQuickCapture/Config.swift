import Foundation

/// App configuration, stored at ~/Library/Application Support/CraftQuickCapture/config.json.
/// The Craft MCP link URL embeds the auth token for your Craft space, so it is
/// never hardcoded — each user pastes their own link on first launch.
struct Config: Codable {
    var mcpUrl: String         // first/primary space link (kept for back-compat)
    var connections: [String]? // all space links; nil = just mcpUrl
    var hotKey: HotKeySpec?    // nil = default ⌥⌘Space

    /// Every configured space link, in order. The first is primary (daily
    /// notes and diagnostics go there).
    var effectiveConnections: [String] {
        if let connections, !connections.isEmpty { return connections }
        return mcpUrl.isEmpty ? [] : [mcpUrl]
    }

    mutating func setConnections(_ urls: [String]) {
        connections = urls
        mcpUrl = urls.first ?? ""
    }

    static var supportDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CraftQuickCapture", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var configFile: URL { supportDir.appendingPathComponent("config.json") }

    static func load() -> Config {
        if let data = try? Data(contentsOf: configFile),
           let cfg = try? JSONDecoder().decode(Config.self, from: data) {
            return cfg
        }
        return Config(mcpUrl: "", connections: nil, hotKey: nil)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: Self.configFile)
        }
    }

    static var isConfigured: Bool {
        let urls = load().effectiveConnections
        return !urls.isEmpty && urls.allSatisfy { URL(string: $0) != nil }
    }
}

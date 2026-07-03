import Foundation

/// App configuration, stored at ~/Library/Application Support/CraftQuickCapture/config.json.
/// The Craft MCP link URL embeds the auth token for your Craft space, so it is
/// never hardcoded — each user pastes their own link on first launch.
struct Config: Codable {
    var mcpUrl: String

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
        return Config(mcpUrl: "")
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: Self.configFile)
        }
    }

    static var isConfigured: Bool {
        let url = load().mcpUrl
        return !url.isEmpty && URL(string: url) != nil
    }
}

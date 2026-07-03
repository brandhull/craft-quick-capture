import Foundation

struct CraftDocument: Codable, Identifiable, Hashable {
    let id: String      // rootBlockId, usable directly with `blocks add --id`
    let title: String
    var folder: String?
}

enum CraftError: LocalizedError {
    case http(Int)
    case tool(String)
    case badResponse
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .http(let code): return "Craft API returned HTTP \(code)"
        case .tool(let msg): return msg
        case .badResponse: return "Unexpected response from Craft"
        case .notConfigured: return "No Craft link set. Menu bar icon → Set Craft Connection…"
        }
    }
}

/// Minimal MCP-over-HTTP client for Craft's link endpoint. The endpoint is
/// stateless — a bare JSON-RPC tools/call works with no initialize handshake —
/// and replies as a single-event SSE stream.
struct CraftClient {
    func call(tool: String, command: String) async throws -> String {
        // Resolved per call so a link pasted via "Set Craft Connection…"
        // takes effect immediately, without recreating clients.
        let urlString = Config.load().mcpUrl
        guard !urlString.isEmpty, let endpoint = URL(string: urlString) else {
            throw CraftError.notConfigured
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": Int.random(in: 1...1_000_000),
            "method": "tools/call",
            "params": ["name": tool, "arguments": ["command": command]]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CraftError.http(http.statusCode)
        }

        // Body is either plain JSON or an SSE stream with `data: {...}` lines.
        let raw = String(decoding: data, as: UTF8.self)
        let jsonText: String
        if raw.hasPrefix("{") {
            jsonText = raw
        } else if let dataLine = raw.split(separator: "\n").first(where: { $0.hasPrefix("data: ") }) {
            jsonText = String(dataLine.dropFirst(6))
        } else {
            throw CraftError.badResponse
        }

        guard let obj = try JSONSerialization.jsonObject(with: Data(jsonText.utf8)) as? [String: Any],
              let result = obj["result"] as? [String: Any],
              let content = result["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String
        else { throw CraftError.badResponse }

        if (result["isError"] as? Bool) == true {
            throw CraftError.tool(text.components(separatedBy: "\n").first ?? text)
        }
        return text
    }

    /// Returns every document, tagged with its folder name. Docs are listed
    /// per folder (so we know where each lives), then a full listing catches
    /// anything unfiled.
    func listAllDocuments() async throws -> [CraftDocument] {
        var docs: [CraftDocument] = []
        var seen = Set<String>()
        for folder in try await listFolders() {
            try await page(command: "documents list --folder \(folder.id)",
                           folderName: folder.name, into: &docs, seen: &seen)
        }
        try await page(command: "documents list", folderName: nil, into: &docs, seen: &seen)
        return docs
    }

    private func listFolders() async throws -> [(id: String, name: String)] {
        let text = try await call(tool: "craft_read", command: "folders list")
        let regex = try NSRegularExpression(pattern: #"<([0-9A-Fa-f-]+)>\s+(.+?)\s+\(\d+ docs?\)"#)
        var folders: [(id: String, name: String)] = []
        for line in text.split(separator: "\n") {
            let s = String(line)
            let range = NSRange(s.startIndex..., in: s)
            guard let m = regex.firstMatch(in: s, range: range),
                  let idR = Range(m.range(at: 1), in: s),
                  let nameR = Range(m.range(at: 2), in: s) else { continue }
            folders.append((id: String(s[idR]), name: String(s[nameR])))
        }
        return folders
    }

    /// Pages through one `documents list` variant. Pagination is cursor-based:
    /// each page ends with "Next page: documents list --cursor X".
    private func page(command baseCommand: String, folderName: String?,
                      into docs: inout [CraftDocument], seen: inout Set<String>) async throws {
        var command = baseCommand
        let lineRegex = try NSRegularExpression(pattern: #"^\s*<([0-9A-Fa-f-]+)>\s+(.+)$"#)
        for _ in 0..<40 { // safety valve: 40 pages ≈ 2000 docs
            let text = try await call(tool: "craft_read", command: command)
            var nextCursor: String?
            for line in text.split(separator: "\n") {
                let s = String(line)
                if s.hasPrefix("Next page:"), let range = s.range(of: "--cursor ") {
                    nextCursor = String(s[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    continue
                }
                let range = NSRange(s.startIndex..., in: s)
                guard let m = lineRegex.firstMatch(in: s, range: range),
                      let idR = Range(m.range(at: 1), in: s),
                      let titleR = Range(m.range(at: 2), in: s) else { continue }
                let id = String(s[idR])
                guard seen.insert(id).inserted else { continue }
                docs.append(CraftDocument(id: id,
                                          title: String(s[titleR]).trimmingCharacters(in: .whitespaces),
                                          folder: folderName))
            }
            guard let cursor = nextCursor else { break }
            command = "\(baseCommand) --cursor \(cursor)"
        }
    }

    /// Appends markdown to the end of a page. Newlines must stay REAL newline
    /// characters — pre-escaping them to literal "\n" makes Craft render them
    /// as literal text and skip markdown parsing (headings become hashtags).
    /// With real newlines: blank line = new block, single newline = soft break,
    /// and heading/list/task markdown renders properly.
    func appendBlocks(pageId: String, markdown: String) async throws {
        let quoted = Self.craftQuote(markdown)
        _ = try await call(tool: "craft_write",
                           command: "blocks add --id \(pageId) --markdown \(quoted) --position end")
    }

    static func craftQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

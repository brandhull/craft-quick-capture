import Foundation

struct CraftDocument: Codable, Identifiable, Hashable {
    let id: String      // rootBlockId (or sub-page block id) for `blocks add --id`
    let title: String
    var folder: String?
    var spaceName: String?  // set when multiple spaces are connected
    var spaceUrl: String?   // MCP link that owns this doc; nil = primary
    var parent: String?     // containing document's title, for sub-pages
}

struct CraftCollection: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let documentId: String  // rootBlockId of the containing document
    var spaceName: String?
    var spaceUrl: String?
}

struct CraftColumn: Codable, Hashable {
    let key: String         // internal key used in --items JSON (lowercase)
    let display: String     // display name shown in Craft
    let type: String        // text, url, number, singleSelect, …
    let isTitle: Bool       // the item-name column; top-level key, not a property
    let options: [String]   // non-empty for select types
}

struct CraftSchema: Codable, Hashable {
    let collectionId: String
    let columns: [CraftColumn]
    var titleKey: String { columns.first(where: \.isTitle)?.key ?? "title" }
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
    /// The MCP link this client talks to. Empty string = unconfigured.
    let url: String

    /// Client for a specific space link. Pass nil to use the primary space.
    init(url: String? = nil) {
        self.url = url ?? Config.load().effectiveConnections.first ?? ""
    }

    func call(tool: String, command: String) async throws -> String {
        guard !url.isEmpty, let endpoint = URL(string: url) else {
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

    /// Appends to a daily note: `day` is today/tomorrow/yesterday or YYYY-MM-DD.
    func appendBlocksToDailyNote(day: String, markdown: String) async throws {
        let quoted = Self.craftQuote(markdown)
        _ = try await call(tool: "craft_write",
                           command: "blocks add --date \(day) --markdown \(quoted) --position end")
    }

    /// Space name from `connection info` (each link is bound to one space).
    func spaceName() async throws -> String {
        let text = try await call(tool: "craft_read", command: "connection info")
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let space = obj["space"] as? [String: Any],
              let name = space["name"] as? String else { throw CraftError.badResponse }
        return name
    }

    /// Sub-pages of a document: depth-1 children with type "page". Capturing
    /// to a sub-page uses `blocks add --id <subPageBlockId>` like any page.
    func listSubPages(of doc: CraftDocument) async throws -> [CraftDocument] {
        let text = try await call(tool: "craft_read",
                                  command: "blocks get \(doc.id) --depth 1 --format json")
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let data = obj["data"] as? [[String: Any]],
              let root = data.first,
              let content = root["content"] as? [[String: Any]]
        else { throw CraftError.badResponse }
        return content.compactMap { block in
            guard (block["type"] as? String) == "page",
                  let id = block["id"] as? String,
                  let title = block["markdown"] as? String else { return nil }
            return CraftDocument(id: id,
                                 title: title.trimmingCharacters(in: .whitespaces),
                                 folder: nil,
                                 spaceName: doc.spaceName,
                                 spaceUrl: doc.spaceUrl,
                                 parent: doc.title)
        }
    }

    /// Parses `collections list`: lines like
    ///   Name <id> - N items (in document <docId>)
    func listCollections() async throws -> [CraftCollection] {
        let text = try await call(tool: "craft_read", command: "collections list")
        let regex = try NSRegularExpression(
            pattern: #"^\s*(.+?)\s+<([0-9A-Fa-f-]+)>\s+-\s+\d+ items? \(in document ([0-9A-Fa-f-]+)\)"#)
        var result: [CraftCollection] = []
        for line in text.split(separator: "\n") {
            let s = String(line)
            let range = NSRange(s.startIndex..., in: s)
            guard let m = regex.firstMatch(in: s, range: range),
                  let nameR = Range(m.range(at: 1), in: s),
                  let idR = Range(m.range(at: 2), in: s),
                  let docR = Range(m.range(at: 3), in: s) else { continue }
            result.append(CraftCollection(id: String(s[idR]),
                                          name: String(s[nameR]),
                                          documentId: String(s[docR])))
        }
        return result
    }

    /// Parses `collections schema`: column lines like
    ///   key → "Display" (type, item name / row headline…) — options: A (color), B (color)
    func collectionSchema(id: String) async throws -> CraftSchema {
        let text = try await call(tool: "craft_read", command: "collections schema --collection \(id)")
        let colRegex = try NSRegularExpression(
            pattern: #"^\s+(\S+) → "(.+?)" \(([^)]*)\)(?:\s+—\s+options:\s+(.+))?$"#)
        var columns: [CraftColumn] = []
        for line in text.split(separator: "\n") {
            let s = String(line)
            let range = NSRange(s.startIndex..., in: s)
            guard let m = colRegex.firstMatch(in: s, range: range),
                  let keyR = Range(m.range(at: 1), in: s),
                  let dispR = Range(m.range(at: 2), in: s),
                  let typeR = Range(m.range(at: 3), in: s) else { continue }
            let typeInfo = String(s[typeR])
            let type = typeInfo.components(separatedBy: ",")[0].trimmingCharacters(in: .whitespaces)
            var options: [String] = []
            if let optR = Range(m.range(at: 4), in: s) {
                // "Todo (yellow), Doing (lime)" → strip the trailing color parens
                options = String(s[optR]).components(separatedBy: ", ").map {
                    $0.replacingOccurrences(of: #" \([^)]*\)$"#, with: "", options: .regularExpression)
                }
            }
            columns.append(CraftColumn(key: String(s[keyR]),
                                       display: String(s[dispR]),
                                       type: type,
                                       isTitle: typeInfo.contains("item name"),
                                       options: options))
        }
        guard !columns.isEmpty else { throw CraftError.badResponse }
        return CraftSchema(collectionId: id, columns: columns)
    }

    /// Adds one row. `values` is keyed by column key; the title column goes
    /// top-level, everything else under "properties". Empty values are omitted.
    func addCollectionItem(schema: CraftSchema, values: [String: String]) async throws {
        var item: [String: Any] = [:]
        var properties: [String: String] = [:]
        for col in schema.columns {
            guard let v = values[col.key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !v.isEmpty else { continue }
            if col.isTitle { item[col.key] = v } else { properties[col.key] = v }
        }
        if item[schema.titleKey] == nil { item[schema.titleKey] = "Untitled" }
        if !properties.isEmpty { item["properties"] = properties }
        let json = try JSONSerialization.data(withJSONObject: [item])
        let itemsArg = String(decoding: json, as: UTF8.self)
        _ = try await call(tool: "craft_write",
                           command: "collections items-add --collection \(schema.collectionId) --items \(itemsArg)")
    }

    static func craftQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

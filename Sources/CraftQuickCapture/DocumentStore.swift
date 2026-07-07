import Foundation

/// A capture destination: a document page (append blocks) or a
/// collection/table (add a row).
enum Destination: Codable, Hashable, Identifiable {
    case document(CraftDocument)
    case collection(CraftCollection)
    case dailyNote(String)   // "today" / "tomorrow" — resolved by Craft at save time

    var id: String {
        switch self {
        case .document(let d): return d.id
        case .collection(let c): return c.id
        case .dailyNote(let day): return "daily:\(day)"
        }
    }

    var title: String {
        switch self {
        case .document(let d): return d.title
        case .collection(let c): return c.name
        case .dailyNote(let day): return day.prefix(1).uppercased() + day.dropFirst()
        }
    }

    var isCollection: Bool {
        if case .collection = self { return true }
        return false
    }

    var isDailyNote: Bool {
        if case .dailyNote = self { return true }
        return false
    }
}

/// Caches the space's documents and collections on disk so the picker is
/// instant, and tracks recently used destinations. Refreshes in the background.
@MainActor
final class DocumentStore: ObservableObject {
    @Published var documents: [CraftDocument] = []
    @Published var collections: [CraftCollection] = []
    @Published var recentIds: [String] = []
    @Published var lastUsedId: String?
    @Published var isRefreshing = false

    @Published var spaceNames: [String: String] = [:]  // link url → space name

    private var lastFetch: Date?
    private var schemaCache: [String: CraftSchema] = [:]

    var hasMultipleSpaces: Bool { Config.load().effectiveConnections.count > 1 }

    private var cacheFile: URL { Config.supportDir.appendingPathComponent("documents.json") }
    private var recentsFile: URL { Config.supportDir.appendingPathComponent("recents.json") }
    private var schemasFile: URL { Config.supportDir.appendingPathComponent("schemas.json") }

    private struct Cache: Codable {
        var fetchedAt: Date
        var docs: [CraftDocument]
        var collections: [CraftCollection]?
        var spaceNames: [String: String]?
    }
    private struct Recents: Codable {
        var ids: [String]
        var lastUsed: String?
    }

    init() {
        if let data = try? Data(contentsOf: cacheFile),
           let cache = try? JSONDecoder().decode(Cache.self, from: data) {
            documents = cache.docs
            collections = cache.collections ?? []
            spaceNames = cache.spaceNames ?? [:]
            lastFetch = cache.fetchedAt
        }
        if let data = try? Data(contentsOf: recentsFile),
           let recents = try? JSONDecoder().decode(Recents.self, from: data) {
            recentIds = recents.ids
            lastUsedId = recents.lastUsed
        }
        if let data = try? Data(contentsOf: schemasFile),
           let schemas = try? JSONDecoder().decode([String: CraftSchema].self, from: data) {
            schemaCache = schemas
        }
        refreshIfStale()
    }

    func refreshIfStale(maxAge: TimeInterval = 15 * 60) {
        // Caches from before folder tagging have no folder on any doc — refetch.
        let missingFolders = !documents.isEmpty && documents.allSatisfy { $0.folder == nil }
        if !missingFolders, let lastFetch,
           Date().timeIntervalSince(lastFetch) < maxAge, !documents.isEmpty { return }
        refresh()
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            defer { isRefreshing = false }
            let urls = Config.load().effectiveConnections
            let multi = urls.count > 1
            var allDocs: [CraftDocument] = []
            var allCols: [CraftCollection] = []
            var names: [String: String] = [:]
            for url in urls {
                let client = CraftClient(url: url)
                do {
                    let name = multi ? ((try? await client.spaceName()) ?? "Space") : nil
                    if let name { names[url] = name }
                    var docs = try await client.listAllDocuments()
                    var cols = (try? await client.listCollections()) ?? []
                    if multi {
                        for i in docs.indices { docs[i].spaceName = name; docs[i].spaceUrl = url }
                        for i in cols.indices { cols[i].spaceName = name; cols[i].spaceUrl = url }
                    }
                    allDocs += docs
                    allCols += cols
                } catch {
                    NSLog("CraftQuickCapture: refresh failed for a space: \(error.localizedDescription)")
                }
            }
            guard !allDocs.isEmpty else { return }
            documents = allDocs
            collections = allCols
            spaceNames = names
            lastFetch = Date()
            let cache = Cache(fetchedAt: Date(), docs: allDocs, collections: allCols, spaceNames: names)
            if let data = try? JSONEncoder().encode(cache) {
                try? data.write(to: cacheFile)
            }
        }
    }

    /// Cached schema immediately if available; fetches (and re-caches) otherwise.
    func schema(for collection: CraftCollection) async throws -> CraftSchema {
        let client = CraftClient(url: collection.spaceUrl)
        if let cached = schemaCache[collection.id] {
            // Refresh in the background so new columns appear next time.
            Task { [weak self] in
                if let fresh = try? await client.collectionSchema(id: collection.id) {
                    self?.storeSchema(fresh)
                }
            }
            return cached
        }
        let fresh = try await client.collectionSchema(id: collection.id)
        storeSchema(fresh)
        return fresh
    }

    private func storeSchema(_ schema: CraftSchema) {
        schemaCache[schema.collectionId] = schema
        if let data = try? JSONEncoder().encode(schemaCache) {
            try? data.write(to: schemasFile)
        }
    }

    /// Folder context for a destination: the document's folder, or for a
    /// collection, the containing document's title.
    func context(for dest: Destination) -> String? {
        var parts: [String] = []
        switch dest {
        case .document(let d):
            if let folder = d.folder { parts.append(folder) }
            if let space = d.spaceName { parts.append(space) }
        case .collection(let c):
            if let doc = documents.first(where: { $0.id == c.documentId }) { parts.append(doc.title) }
            if let space = c.spaceName { parts.append(space) }
        case .dailyNote:
            parts.append("Daily note")
            if hasMultipleSpaces,
               let primary = Config.load().effectiveConnections.first,
               let name = spaceNames[primary] {
                parts.append(name)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func markUsed(_ dest: Destination) {
        recentIds.removeAll { $0 == dest.id }
        recentIds.insert(dest.id, at: 0)
        recentIds = Array(recentIds.prefix(8))
        lastUsedId = dest.id
        let recents = Recents(ids: recentIds, lastUsed: lastUsedId)
        if let data = try? JSONEncoder().encode(recents) {
            try? data.write(to: recentsFile)
        }
    }

    private func destination(forId id: String) -> Destination? {
        if id.hasPrefix("daily:") { return .dailyNote(String(id.dropFirst(6))) }
        if let d = documents.first(where: { $0.id == id }) { return .document(d) }
        if let c = collections.first(where: { $0.id == id }) { return .collection(c) }
        return nil
    }

    var recentDestinations: [Destination] {
        recentIds.compactMap { destination(forId: $0) }
    }

    var lastUsedDestination: Destination? {
        guard let lastUsedId else { return nil }
        return destination(forId: lastUsedId)
    }

    /// Case-insensitive match over documents AND collections. Every
    /// space-separated token must appear in the title or context (folder /
    /// containing doc), so a folder word narrows same-named docs.
    /// Ranking: title prefix beats title word-start beats any match.
    func search(_ query: String, limit: Int = 6) -> [Destination] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty {
            // "Today" always leads; then recents (which may include it — dedupe).
            var results: [Destination] = [.dailyNote("today")]
            results += recentDestinations.filter { $0.id != "daily:today" }
            return Array(results.prefix(limit))
        }
        var pinned: [Destination] = []
        if "today".hasPrefix(q) { pinned.append(.dailyNote("today")) }
        if "tomorrow".hasPrefix(q) { pinned.append(.dailyNote("tomorrow")) }
        if "yesterday".hasPrefix(q) { pinned.append(.dailyNote("yesterday")) }
        let tokens = q.split(separator: " ").map(String.init)
        var scored: [(dest: Destination, score: Int)] = []

        func consider(_ dest: Destination) {
            let t = dest.title.lowercased()
            let hay = t + " " + (context(for: dest)?.lowercased() ?? "")
            guard tokens.allSatisfy({ hay.contains($0) }) else { return }
            if t.hasPrefix(q) { scored.append((dest, 0)) }
            else if t.contains(" \(q)") { scored.append((dest, 1)) }
            else { scored.append((dest, 2)) }
        }
        for c in collections { consider(.collection(c)) }
        for d in documents { consider(.document(d)) }

        return pinned + scored.sorted { ($0.score, $0.dest.title) < ($1.score, $1.dest.title) }
            .prefix(max(0, limit - pinned.count)).map(\.dest)
    }
}

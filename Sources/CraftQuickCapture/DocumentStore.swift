import Foundation

/// Caches the space's document list on disk so the picker is instant, and
/// tracks recently used destinations. Refreshes in the background.
@MainActor
final class DocumentStore: ObservableObject {
    @Published var documents: [CraftDocument] = []
    @Published var recentIds: [String] = []
    @Published var lastUsedId: String?
    @Published var isRefreshing = false

    private let client = CraftClient()
    private var lastFetch: Date?

    private var cacheFile: URL { Config.supportDir.appendingPathComponent("documents.json") }
    private var recentsFile: URL { Config.supportDir.appendingPathComponent("recents.json") }

    private struct Cache: Codable {
        var fetchedAt: Date
        var docs: [CraftDocument]
    }
    private struct Recents: Codable {
        var ids: [String]
        var lastUsed: String?
    }

    init() {
        if let data = try? Data(contentsOf: cacheFile),
           let cache = try? JSONDecoder().decode(Cache.self, from: data) {
            documents = cache.docs
            lastFetch = cache.fetchedAt
        }
        if let data = try? Data(contentsOf: recentsFile),
           let recents = try? JSONDecoder().decode(Recents.self, from: data) {
            recentIds = recents.ids
            lastUsedId = recents.lastUsed
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
            do {
                let docs = try await client.listAllDocuments()
                guard !docs.isEmpty else { return }
                documents = docs
                lastFetch = Date()
                let cache = Cache(fetchedAt: Date(), docs: docs)
                if let data = try? JSONEncoder().encode(cache) {
                    try? data.write(to: cacheFile)
                }
            } catch {
                NSLog("CraftQuickCapture: document refresh failed: \(error.localizedDescription)")
            }
        }
    }

    func markUsed(_ doc: CraftDocument) {
        recentIds.removeAll { $0 == doc.id }
        recentIds.insert(doc.id, at: 0)
        recentIds = Array(recentIds.prefix(8))
        lastUsedId = doc.id
        let recents = Recents(ids: recentIds, lastUsed: lastUsedId)
        if let data = try? JSONEncoder().encode(recents) {
            try? data.write(to: recentsFile)
        }
    }

    var recentDocuments: [CraftDocument] {
        let byId = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
        return recentIds.compactMap { byId[$0] }
    }

    var lastUsedDocument: CraftDocument? {
        guard let lastUsedId else { return nil }
        return documents.first { $0.id == lastUsedId }
    }

    /// Case-insensitive match. Every space-separated token must appear in the
    /// title or folder name (so a folder word narrows same-named docs).
    /// Ranking: title prefix beats title word-start beats any match.
    func search(_ query: String, limit: Int = 6) -> [CraftDocument] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Array(recentDocuments.prefix(limit)) }
        let tokens = q.split(separator: " ").map(String.init)
        var scored: [(doc: CraftDocument, score: Int)] = []
        for doc in documents {
            let t = doc.title.lowercased()
            let hay = t + " " + (doc.folder?.lowercased() ?? "")
            guard tokens.allSatisfy({ hay.contains($0) }) else { continue }
            if t.hasPrefix(q) { scored.append((doc, 0)) }
            else if t.contains(" \(q)") { scored.append((doc, 1)) }
            else { scored.append((doc, 2)) }
        }
        return scored.sorted { ($0.score, $0.doc.title) < ($1.score, $1.doc.title) }
            .prefix(limit).map(\.doc)
    }
}

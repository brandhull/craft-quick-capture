import AppKit
import SwiftUI

@MainActor
final class CaptureModel: ObservableObject {
    @Published var text = ""
    @Published var imageData: Data?
    @Published var imagePreview: NSImage?
    @Published var docQuery = ""
    @Published var selectedDestination: Destination?
    @Published var isPickingDoc = false
    @Published var highlightedIndex = 0
    @Published var isSaving = false
    @Published var editorHeight: CGFloat = 64
    @Published var focusEditorTick = 0
    @Published var hotKeyDisplay = (Config.load().hotKey ?? .default).display

    // Drill-in: when set, the picker shows this document's sub-pages.
    @Published var expandedDoc: CraftDocument?
    @Published var expandedSubPages: [CraftDocument] = []
    @Published var isLoadingSubPages = false
    @Published var errorMessage: String?
    @Published var justSaved = false

    // Table capture: schema of the selected collection and per-column values.
    @Published var schema: CraftSchema?
    @Published var fieldValues: [String: String] = [:]
    @Published var isLoadingSchema = false

    let store: DocumentStore
    var onClose: (() -> Void)?

    /// Client for the space that owns the destination (primary for daily notes).
    private func client(for dest: Destination) -> CraftClient {
        switch dest {
        case .document(let d): return CraftClient(url: d.spaceUrl)
        case .collection(let c): return CraftClient(url: c.spaceUrl)
        case .dailyNote: return CraftClient()
        }
    }

    init(store: DocumentStore) {
        self.store = store
    }

    var searchResults: [Destination] { store.search(docQuery) }

    /// What the picker shows: sub-pages of the expanded doc, or search results.
    var displayedResults: [Destination] {
        guard expandedDoc != nil else { return searchResults }
        let q = docQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let subs = q.isEmpty ? expandedSubPages
                             : expandedSubPages.filter { $0.title.lowercased().contains(q) }
        return subs.map { .document($0) }
    }

    func expandHighlighted() {
        let results = displayedResults
        guard expandedDoc == nil,
              results.indices.contains(highlightedIndex),
              case .document(let doc) = results[highlightedIndex],
              doc.parent == nil    // sub-pages don't drill further
        else { return }
        expand(doc)
    }

    func expand(_ doc: CraftDocument) {
        expandedDoc = doc
        expandedSubPages = store.knownSubPages[doc.id] ?? []  // instant if seen before
        docQuery = ""
        highlightedIndex = 0
        isLoadingSubPages = true
        Task {
            defer { isLoadingSubPages = false }
            do {
                let subs = try await store.subPages(of: doc)
                if expandedDoc?.id == doc.id { expandedSubPages = subs }
            } catch {
                if expandedDoc?.id == doc.id, expandedSubPages.isEmpty {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func collapseExpansion() {
        expandedDoc = nil
        expandedSubPages = []
        docQuery = ""
        highlightedIndex = 0
    }

    var isTableCapture: Bool { selectedDestination?.isCollection == true }

    var canSave: Bool {
        guard selectedDestination != nil, !isSaving else { return false }
        if isTableCapture {
            guard let schema else { return false }
            return imageData == nil &&
                schema.columns.contains { !(fieldValues[$0.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || imageData != nil
    }

    func prepareForShow() {
        errorMessage = nil
        justSaved = false
        if selectedDestination == nil {
            select(store.lastUsedDestination)
        }
        store.refreshIfStale()
    }

    func setImage(_ data: Data) {
        guard let img = NSImage(data: data) else { return }
        imageData = data
        imagePreview = img
    }

    func clearImage() {
        imageData = nil
        imagePreview = nil
    }

    func pasteImageIfPresent() -> Bool {
        let pb = NSPasteboard.general
        // Only intercept ⌘V when the pasteboard is an image, not text.
        guard pb.string(forType: .string) == nil else { return false }
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) {
            setImage(data)
            return true
        }
        return false
    }

    func choose(_ dest: Destination) {
        select(dest)
        docQuery = ""
        isPickingDoc = false
        highlightedIndex = 0
        expandedDoc = nil
        expandedSubPages = []
    }

    private func select(_ dest: Destination?) {
        selectedDestination = dest
        schema = nil
        guard case .collection(let collection)? = dest else { return }
        isLoadingSchema = true
        Task {
            defer { isLoadingSchema = false }
            do {
                let s = try await store.schema(for: collection)
                // Still the selected destination? (user may have re-picked)
                if case .collection(let current)? = selectedDestination, current.id == collection.id {
                    schema = s
                    fieldValues = fieldValues.filter { pair in s.columns.contains { $0.key == pair.key } }
                    // Seed the title field from any text already typed.
                    if fieldValues[s.titleKey, default: ""].isEmpty, !text.isEmpty {
                        fieldValues[s.titleKey] = text
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func moveHighlight(_ delta: Int) {
        let count = displayedResults.count
        guard count > 0 else { return }
        highlightedIndex = (highlightedIndex + delta + count) % count
    }

    func chooseHighlighted() {
        let results = displayedResults
        guard results.indices.contains(highlightedIndex) else { return }
        choose(results[highlightedIndex])
    }

    func save() {
        guard canSave, let dest = selectedDestination else { return }
        isSaving = true
        errorMessage = nil
        let client = client(for: dest)
        Task {
            do {
                switch dest {
                case .document, .dailyNote:
                    let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    func markdown(imageURL: String?) -> String {
                        guard let imageURL else { return body }
                        return body.isEmpty ? "![image](\(imageURL))"
                                            : body + "\n\n![image](\(imageURL))"
                    }
                    func append(_ md: String) async throws {
                        if case .document(let doc) = dest {
                            try await client.appendBlocks(pageId: doc.id, markdown: md)
                        } else if case .dailyNote(let day) = dest {
                            try await client.appendBlocksToDailyNote(day: day, markdown: md)
                        }
                    }
                    if let image = imageData {
                        let name = "capture-\(Int(Date().timeIntervalSince1970)).png"
                        let url = try await ImageUploader.upload(image, filename: name)
                        do {
                            try await append(markdown(imageURL: url))
                        } catch CraftError.tool(let msg) where msg.contains("Document not found") {
                            // Craft reports a failed image fetch as "Document not
                            // found" — re-relay through the other host and retry.
                            let retryUrl = try await ImageUploader.upload(image, filename: name,
                                                                          preferLitterbox: true)
                            do {
                                try await append(markdown(imageURL: retryUrl))
                            } catch CraftError.tool(let msg2) where msg2.contains("Document not found") {
                                throw CraftError.tool("Craft couldn't ingest the image (tried both relay hosts). Text was not saved — try again.")
                            }
                        }
                    } else {
                        try await append(markdown(imageURL: nil))
                    }
                case .collection:
                    guard let schema else { return }
                    try await client.addCollectionItem(schema: schema, values: fieldValues)
                }
                store.markUsed(dest)
                justSaved = true
                isSaving = false
                // Brief success flash, then close and reset.
                try? await Task.sleep(nanoseconds: 450_000_000)
                reset()
                onClose?()
            } catch {
                isSaving = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func reset() {
        text = ""
        clearImage()
        docQuery = ""
        isPickingDoc = false
        highlightedIndex = 0
        errorMessage = nil
        justSaved = false
        fieldValues = [:]
        expandedDoc = nil
        expandedSubPages = []
    }
}

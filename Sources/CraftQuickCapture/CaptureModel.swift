import AppKit
import SwiftUI

@MainActor
final class CaptureModel: ObservableObject {
    @Published var text = ""
    @Published var imageData: Data?
    @Published var imagePreview: NSImage?
    @Published var docQuery = ""
    @Published var selectedDoc: CraftDocument?
    @Published var isPickingDoc = false
    @Published var highlightedIndex = 0
    @Published var isSaving = false
    @Published var errorMessage: String?
    @Published var justSaved = false

    let store: DocumentStore
    var onClose: (() -> Void)?

    private let client = CraftClient()

    init(store: DocumentStore) {
        self.store = store
    }

    var searchResults: [CraftDocument] { store.search(docQuery) }

    var canSave: Bool {
        selectedDoc != nil && !isSaving &&
        (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || imageData != nil)
    }

    func prepareForShow() {
        errorMessage = nil
        justSaved = false
        if selectedDoc == nil { selectedDoc = store.lastUsedDocument }
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

    func choose(_ doc: CraftDocument) {
        selectedDoc = doc
        docQuery = ""
        isPickingDoc = false
        highlightedIndex = 0
    }

    func moveHighlight(_ delta: Int) {
        let count = searchResults.count
        guard count > 0 else { return }
        highlightedIndex = (highlightedIndex + delta + count) % count
    }

    func chooseHighlighted() {
        let results = searchResults
        guard results.indices.contains(highlightedIndex) else { return }
        choose(results[highlightedIndex])
    }

    func save() {
        guard canSave, let doc = selectedDoc else { return }
        isSaving = true
        errorMessage = nil
        let body = text
        let image = imageData
        Task {
            do {
                var markdown = body.trimmingCharacters(in: .whitespacesAndNewlines)
                if let image {
                    let name = "capture-\(Int(Date().timeIntervalSince1970)).png"
                    let url = try await ImageUploader.upload(image, filename: name)
                    markdown = markdown.isEmpty ? "![image](\(url))" : markdown + "\n\n![image](\(url))"
                }
                try await client.appendBlocks(pageId: doc.id, markdown: markdown)
                store.markUsed(doc)
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
    }
}

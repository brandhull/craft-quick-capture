import SwiftUI
import UniformTypeIdentifiers

private enum Palette {
    static let card = Color(red: 0.16, green: 0.16, blue: 0.18)
    static let cardBorder = Color.white.opacity(0.08)
    static let pill = Color.white.opacity(0.09)
    static let accent = Color(red: 0.48, green: 0.43, blue: 0.94)
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.45)
    static let rowHighlight = Color.white.opacity(0.10)
}

struct CaptureView: View {
    @ObservedObject var model: CaptureModel
    @FocusState private var focus: Field?

    enum Field { case editor, docSearch }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            editor
            if let preview = model.imagePreview {
                imageRow(preview)
            }
            destination
            if let error = model.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 1.0, green: 0.45, blue: 0.45))
                    .lineLimit(2)
            }
            footer
        }
        .padding(18)
        .frame(width: 560)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Palette.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Palette.cardBorder, lineWidth: 1)
                )
        )
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focus = .editor }
        }
        .onChange(of: model.isPickingDoc) { picking in
            focus = picking ? .docSearch : .editor
        }
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Palette.textSecondary)
            Text("Quick Capture")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Palette.textSecondary)
            Spacer()
            Text("⌥⌘Space")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(Palette.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Palette.pill))
        }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if model.text.isEmpty {
                Text("Type something, or drop an image…")
                    .font(.system(size: 15))
                    .foregroundColor(Palette.textSecondary.opacity(0.7))
                    .padding(.top, 1)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $model.text)
                .font(.system(size: 15))
                .foregroundColor(Palette.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 64, maxHeight: 180)
                .fixedSize(horizontal: false, vertical: true)
                .focused($focus, equals: .editor)
                .padding(.leading, -5) // align TextEditor's inset with the placeholder
        }
    }

    private func imageRow(_ preview: NSImage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(nsImage: preview)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 110)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.cardBorder))
            Button {
                model.clearImage()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundColor(Palette.textSecondary)
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    private var destination: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.right.doc.on.clipboard")
                    .font(.system(size: 11))
                    .foregroundColor(Palette.textSecondary)

                if model.isPickingDoc {
                    TextField("Search documents…", text: $model.docQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(Palette.textPrimary)
                        .focused($focus, equals: .docSearch)
                        .onChange(of: model.docQuery) { _ in model.highlightedIndex = 0 }
                } else {
                    Button {
                        model.isPickingDoc = true
                    } label: {
                        HStack(spacing: 6) {
                            Text(model.selectedDoc?.title ?? "Choose a document…")
                                .font(.system(size: 13, weight: model.selectedDoc == nil ? .regular : .medium))
                                .foregroundColor(model.selectedDoc == nil ? Palette.textSecondary : Palette.textPrimary)
                                .lineLimit(1)
                            if let folder = model.selectedDoc?.folder {
                                Text("· \(folder)")
                                    .font(.system(size: 11))
                                    .foregroundColor(Palette.textSecondary)
                                    .lineLimit(1)
                            }
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9))
                                .foregroundColor(Palette.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if model.store.isRefreshing {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(Palette.pill))

            if model.isPickingDoc {
                resultsList
            }
        }
    }

    private var resultsList: some View {
        VStack(alignment: .leading, spacing: 2) {
            let results = model.searchResults
            if results.isEmpty {
                Text(model.docQuery.isEmpty ? "No recent documents — type to search" : "No matches")
                    .font(.system(size: 12))
                    .foregroundColor(Palette.textSecondary)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
            }
            ForEach(Array(results.enumerated()), id: \.element.id) { index, doc in
                Button {
                    model.choose(doc)
                } label: {
                    HStack {
                        Text(doc.title)
                            .font(.system(size: 12.5))
                            .foregroundColor(Palette.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        if let folder = doc.folder {
                            Text(folder)
                                .font(.system(size: 10.5))
                                .foregroundColor(Palette.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(index == model.highlightedIndex ? Palette.rowHighlight : .clear)
                    )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { model.highlightedIndex = index }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("⌘↩ save · esc cancel")
                .font(.system(size: 10.5))
                .foregroundColor(Palette.textSecondary)
            Spacer()
            Button(action: { model.save() }) {
                Group {
                    if model.justSaved {
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                    } else if model.isSaving {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else {
                        Text("Save").font(.system(size: 12.5, weight: .semibold))
                    }
                }
                .foregroundColor(.white)
                .frame(width: 62, height: 27)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(model.canSave || model.justSaved ? Palette.accent : Palette.accent.opacity(0.35))
                )
            }
            .buttonStyle(.plain)
            .disabled(!model.canSave)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil),
                          let fileData = try? Data(contentsOf: url),
                          NSImage(data: fileData) != nil else { return }
                    DispatchQueue.main.async { model.setImage(fileData) }
                }
                return true
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    DispatchQueue.main.async { model.setImage(data) }
                }
                return true
            }
        }
        return false
    }
}

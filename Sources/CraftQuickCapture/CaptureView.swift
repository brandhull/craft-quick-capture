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
    var onHeightChange: (CGFloat) -> Void = { _ in }
    @FocusState private var focus: Field?

    enum Field: Hashable { case editor, docSearch, column(String) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.isTableCapture {
                tableForm
            } else {
                editor
                if let preview = model.imagePreview {
                    imageRow(preview)
                }
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
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { onHeightChange(proxy.size.height) }
                    .onChange(of: proxy.size.height) { onHeightChange($0) }
            }
        )
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            guard !model.isTableCapture else { return false }
            return handleDrop(providers)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focusPrimary() }
        }
        .onChange(of: model.isPickingDoc) { picking in
            if picking { focus = .docSearch } else { focusPrimary() }
        }
        .onChange(of: model.schema) { _ in
            if model.isTableCapture { focusPrimary() }
        }
        .environment(\.colorScheme, .dark)
    }

    private func focusPrimary() {
        if model.isTableCapture {
            if let key = model.schema?.titleKey { focus = .column(key) }
        } else {
            model.focusEditorTick += 1
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: model.isTableCapture ? "tablecells" : "square.and.pencil")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Palette.textSecondary)
            Text(model.isTableCapture ? "Quick Capture — table row" : "Quick Capture")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Palette.textSecondary)
            Spacer()
            Text(model.hotKeyDisplay)
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
            CaptureTextView(text: $model.text,
                            focusTick: model.focusEditorTick,
                            onHeightChange: { model.editorHeight = $0 })
                .frame(height: min(max(model.editorHeight, 64), 180))
        }
    }

    private var tableForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isLoadingSchema {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("Loading columns…")
                        .font(.system(size: 12))
                        .foregroundColor(Palette.textSecondary)
                }
                .frame(minHeight: 64)
            } else if let schema = model.schema {
                ForEach(schema.columns, id: \.key) { column in
                    columnField(column)
                }
                if model.imageData != nil {
                    Text("Images can't go into table rows — remove the image or pick a document.")
                        .font(.system(size: 11))
                        .foregroundColor(Color(red: 1.0, green: 0.75, blue: 0.4))
                }
            }
        }
    }

    private func columnField(_ column: CraftColumn) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(column.display)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(Palette.textSecondary)
                .frame(width: 90, alignment: .trailing)
                .lineLimit(1)

            if !column.options.isEmpty {
                Menu {
                    Button("—") { model.fieldValues[column.key] = "" }
                    ForEach(column.options, id: \.self) { option in
                        Button(option) { model.fieldValues[column.key] = option }
                    }
                } label: {
                    Text(model.fieldValues[column.key, default: ""].isEmpty
                         ? "Choose…" : model.fieldValues[column.key, default: ""])
                        .font(.system(size: 13))
                        .foregroundColor(model.fieldValues[column.key, default: ""].isEmpty
                                         ? Palette.textSecondary : Palette.textPrimary)
                }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7).fill(Palette.pill))
            } else {
                TextField(column.isTitle ? "Row title" : column.display,
                          text: binding(for: column.key),
                          axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .font(.system(size: 13, weight: column.isTitle ? .medium : .regular))
                    .foregroundColor(Palette.textPrimary)
                    .focused($focus, equals: .column(column.key))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Palette.pill))
            }
        }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(get: { model.fieldValues[key, default: ""] },
                set: { model.fieldValues[key] = $0 })
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
                Image(systemName: model.isTableCapture ? "tablecells" : "arrow.right.doc.on.clipboard")
                    .font(.system(size: 11))
                    .foregroundColor(Palette.textSecondary)

                if model.isPickingDoc {
                    TextField("Search documents and tables…", text: $model.docQuery)
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
                            Text(model.selectedDestination?.title ?? "Choose a destination…")
                                .font(.system(size: 13, weight: model.selectedDestination == nil ? .regular : .medium))
                                .foregroundColor(model.selectedDestination == nil ? Palette.textSecondary : Palette.textPrimary)
                                .lineLimit(1)
                            if let dest = model.selectedDestination,
                               let context = model.store.context(for: dest) {
                                Text("· \(context)")
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
            let results = model.displayedResults
            if let expanded = model.expandedDoc {
                Button {
                    model.collapseExpansion()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 9, weight: .semibold))
                        Text(expanded.title)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                        if model.isLoadingSubPages {
                            ProgressView().controlSize(.small).scaleEffect(0.5)
                        }
                        Spacer()
                    }
                    .foregroundColor(Palette.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            if results.isEmpty {
                Text(model.expandedDoc != nil
                     ? (model.isLoadingSubPages ? "Loading sub-pages…" : "No sub-pages")
                     : (model.docQuery.isEmpty ? "No recent destinations — type to search" : "No matches"))
                    .font(.system(size: 12))
                    .foregroundColor(Palette.textSecondary)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
            }
            ForEach(Array(results.enumerated()), id: \.element.id) { index, dest in
                Button {
                    model.choose(dest)
                } label: {
                    HStack(spacing: 6) {
                        if dest.isCollection {
                            Image(systemName: "tablecells")
                                .font(.system(size: 10))
                                .foregroundColor(Palette.textSecondary)
                        } else if dest.isDailyNote {
                            Image(systemName: "calendar")
                                .font(.system(size: 10))
                                .foregroundColor(Palette.textSecondary)
                        }
                        Text(dest.title)
                            .font(.system(size: 12.5))
                            .foregroundColor(Palette.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        if let context = model.store.context(for: dest) {
                            Text(context)
                                .font(.system(size: 10.5))
                                .foregroundColor(Palette.textSecondary)
                                .lineLimit(1)
                        }
                        if canDrillIn(dest) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(Palette.textSecondary.opacity(
                                    index == model.highlightedIndex ? 1 : 0.35))
                                .onTapGesture {
                                    if case .document(let doc) = dest { model.expand(doc) }
                                }
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

    private func canDrillIn(_ dest: Destination) -> Bool {
        guard model.expandedDoc == nil,
              case .document(let doc) = dest, doc.parent == nil else { return false }
        return true
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

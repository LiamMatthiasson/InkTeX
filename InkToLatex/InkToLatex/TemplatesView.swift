// Your taught templates, grouped by label: swipe to delete, Rename to fix a label.
// The built-in starters aren't listed.

import SwiftUI
import UniformTypeIdentifiers

struct IndexedTemplate: Identifiable {
    let index: Int            // position in model.templates
    let template: Template
    var id: Int { index }
}

struct TemplateGroup: Identifiable {
    let label: String
    let items: [IndexedTemplate]
    var id: String { label }
}

struct TemplatesView: View {
    let model: NoteModel
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: IndexedTemplate?
    @State private var newLabel = ""
    @State private var importing = false              // the Files picker is open
    @State private var importMessage: String?         // what the last import did

    private var groups: [TemplateGroup] {
        let indexed = model.templates.enumerated().map { IndexedTemplate(index: $0.offset, template: $0.element) }
        let byLabel = Dictionary(grouping: indexed) { $0.template.label }
        return byLabel.keys.sorted().map { TemplateGroup(label: $0, items: byLabel[$0]!) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let importMessage {
                    Text(importMessage)
                        .foregroundStyle(Color.padGreen)
                }
                if model.templates.isEmpty {
                    Text("Nothing taught yet. Write a symbol, type what it is, and tap Teach, or tap a symbol in the LaTeX panel to correct it.")
                        .foregroundStyle(Color.muted)
                }
                ForEach(groups) { group in
                    Section {
                        ForEach(group.items) { item in
                            row(item)
                        }
                        .onDelete { offsets in
                            // Highest first, so the other positions don't shift
                            let positions = offsets.map { group.items[$0].index }.sorted(by: >)
                            positions.forEach { model.deleteTemplate(at: $0) }
                        }
                    } header: {
                        HStack {
                            Text(group.label)
                                .font(.system(.headline, design: .monospaced))
                                .textCase(nil)                 // keep "\alpha" as typed
                            Spacer()
                            Text("\(group.items.count)")
                        }
                    }
                }
            }
            .navigationTitle("Your templates (\(model.templates.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    // Back up your templates: save the file to Files, AirDrop it, email it…
                    ShareLink(item: TemplatesFile(data: model.templatesBackup()),
                              preview: SharePreview("InkTeX templates.json")) {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .disabled(model.templates.isEmpty)

                    // …and bring a backup back (after reinstalling, or on another iPad)
                    Button {
                        importing = true
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                guard case .success(let url) = result else { return }
                // Files from the Files app are outside our sandbox: ask for access first
                let allowed = url.startAccessingSecurityScopedResource()
                defer { if allowed { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    importMessage = model.importTemplates(from: data)
                } else {
                    importMessage = "Couldn't read that file"
                }
            }
            .alert("Change label", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("LaTeX, e.g. 2 or \\alpha", text: $newLabel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save") {
                    if let item = renaming { model.renameTemplate(at: item.index, to: newLabel) }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            } message: {
                Text("Just the symbol itself: 2, not ^2. Raised or lowered is worked out from where you write it.")
            }
        }
    }

    private func row(_ item: IndexedTemplate) -> some View {
        HStack(spacing: 14) {
            InkPreview(strokes: item.template.strokes)
                .frame(width: 48, height: 48)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.rule))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.template.label)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Color.ink)
                if let guessed = item.template.guessed {
                    Text("a correction: it was read as \(guessed)")
                        .font(.caption)
                        .foregroundStyle(Color.muted)
                }
            }
            Spacer()
            Button("Rename") {
                newLabel = item.template.label
                renaming = item
            }
            .buttonStyle(.borderless)
        }
    }
}

/// Strokes scaled to fit, centered.
struct InkPreview: View {
    let strokes: [[Point]]

    var body: some View {
        Canvas { context, size in
            let points = strokes.flatMap { $0 }
            guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                  let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return }
            let inset = 6.0
            let scale = min((size.width - 2 * inset) / max(maxX - minX, 1),
                            (size.height - 2 * inset) / max(maxY - minY, 1))
            let offsetX = (size.width - (maxX - minX) * scale) / 2
            let offsetY = (size.height - (maxY - minY) * scale) / 2
            func spot(_ p: Point) -> CGPoint {
                CGPoint(x: (p.x - minX) * scale + offsetX, y: (p.y - minY) * scale + offsetY)
            }

            var path = Path()
            for stroke in strokes {
                guard let first = stroke.first else { continue }
                path.move(to: spot(first))
                if stroke.count == 1 { path.addLine(to: CGPoint(x: spot(first).x + 0.5, y: spot(first).y)) }
                for p in stroke.dropFirst() { path.addLine(to: spot(p)) }
            }
            context.stroke(path, with: .color(Color.ink),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}

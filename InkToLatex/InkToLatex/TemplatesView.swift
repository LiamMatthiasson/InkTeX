// The Templates screen: everything you've taught, grouped by symbol, each with a small
// picture of the ink. Swipe left to delete one; tap Rename to fix its label. Only YOUR
// templates are listed (the ~670 built-in ones from the dataset can't be changed here).

import SwiftUI

/// One of your templates, with its position in `model.templates` (needed to delete it).
struct IndexedTemplate: Identifiable {
    let index: Int
    let template: Template
    var id: Int { index }
}

/// All your templates for one label ("2", "\alpha"…).
struct TemplateGroup: Identifiable {
    let label: String
    let items: [IndexedTemplate]
    var id: String { label }
}

struct TemplatesView: View {
    let model: NoteModel
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: IndexedTemplate?     // the template "Rename" is for
    @State private var newLabel = ""

    /// Your templates grouped by label, labels in alphabetical order.
    private var groups: [TemplateGroup] {
        let indexed = model.templates.enumerated().map { IndexedTemplate(index: $0.offset, template: $0.element) }
        let byLabel = Dictionary(grouping: indexed) { $0.template.label }
        return byLabel.keys.sorted().map { TemplateGroup(label: $0, items: byLabel[$0]!) }
    }

    var body: some View {
        NavigationStack {
            List {
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
                            // Delete from the highest position down, so the positions of
                            // the others don't shift underneath us.
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
                Button("Done") { dismiss() }
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
                    Text("a correction: it was read as \(guessed)")   // from tapping a chip
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

/// A small picture of some strokes, scaled to fit (keeping their shape).
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
            // center the ink in the box
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

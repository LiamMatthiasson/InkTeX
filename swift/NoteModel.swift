// The app's state and logic: templates (teach mode), grouping strokes into
// symbols, and building the LaTeX. This is the Swift version of the non-drawing
// half of app.js. The screen lives in ContentView; the ink lives in InkCanvas.

import Foundation
import Observation

/// One recognized symbol on the page: its strokes, its LaTeX label, and its left edge.
struct Symbol {
    var strokes: [[Point]]
    var label: String
    var x: Double
}

@Observable
final class NoteModel {
    // Templates: raw ones are saved; prepared ones (normalized once) are used for matching.
    private(set) var templates: [Template] = []
    private var prepared: [PreparedTemplate] = []

    // What's on the page right now
    private(set) var symbols: [Symbol] = []
    private var allStrokes: [[Point]] = []   // everything drawn since the last Erase (used by Save)
    private var lastPenUp: TimeInterval = 0

    var status = ""

    // Grouping rule (same as the web version)
    let groupTime: TimeInterval = 1.0   // a stroke started within 1 s of the last pen-up may join it
    let groupMargin = 10.0              // points of slack when checking horizontal overlap

    /// The symbols sorted left to right, labels joined with spaces.
    var latex: String {
        symbols.sorted { $0.x < $1.x }
               .map { $0.label }
               .joined(separator: " ")
    }

    init() {
        loadTemplates()
        status = "\(templates.count) templates saved"
    }

    // MARK: - Strokes

    /// Called by the canvas each time the pen lifts.
    func strokeFinished(_ points: [Point], startTime: TimeInterval, endTime: TimeInterval) {
        guard !points.isEmpty else { return }
        allStrokes.append(points)

        guard !prepared.isEmpty else { return }   // nothing to recognize against yet

        // Does this stroke belong to the symbol written just before it?
        // Yes if it started soon after the last stroke AND overlaps it left to right.
        let quick = startTime - lastPenUp < groupTime
        lastPenUp = endTime

        if let last = symbols.indices.last, quick, overlapsX(symbols[last].strokes, [points]) {
            symbols[last].strokes.append(points)          // same symbol: add this stroke
            relabel(last)
        } else {
            symbols.append(Symbol(strokes: [points], label: "", x: 0))   // a new symbol
            relabel(symbols.count - 1)
        }
    }

    /// (Re)recognize one symbol, so a "-" becomes a "+" once its second line arrives.
    private func relabel(_ index: Int) {
        let results = recognize(symbols[index].strokes, templates: prepared)
        symbols[index].label = results.first?.label ?? "?"
        symbols[index].x = xRange(symbols[index].strokes).min
        print(results.map { "\($0.label): \(String(format: "%.3f", $0.score))" })
    }

    /// Forget everything on the page (the canvas clears itself separately).
    func clearPage() {
        allStrokes = []
        symbols = []
        lastPenUp = 0
    }

    // MARK: - Grouping helpers

    private func xRange(_ strokeList: [[Point]]) -> (min: Double, max: Double) {
        var minX = Double.infinity, maxX = -Double.infinity
        for stroke in strokeList {
            for p in stroke {
                minX = min(minX, p.x)
                maxX = max(maxX, p.x)
            }
        }
        return (minX, maxX)
    }

    private func overlapsX(_ a: [[Point]], _ b: [[Point]]) -> Bool {
        let ra = xRange(a)
        let rb = xRange(b)
        return rb.min <= ra.max + groupMargin && rb.max >= ra.min - groupMargin
    }

    // MARK: - Templates (teach mode)

    /// Saves everything on the page as a template. Returns true if it saved
    /// (the caller then clears the canvas).
    func saveTemplate(label rawLabel: String) -> Bool {
        let label = rawLabel.trimmingCharacters(in: .whitespaces)   // the label is the LaTeX
        guard !label.isEmpty else { status = "Type a label first"; return false }
        guard !allStrokes.isEmpty else { status = "Draw something first"; return false }

        let template = Template(label: label, strokes: allStrokes)
        templates.append(template)
        prepared.append(PreparedTemplate(template))   // normalized once, right now
        persistTemplates()
        status = "Saved \"\(label)\" (\(templates.count) total)"
        return true
    }

    func undoTemplate() {
        guard let removed = templates.popLast() else { status = "No templates to undo"; return }
        prepared.removeLast()
        persistTemplates()
        status = "Removed \"\(removed.label)\" (\(templates.count) total)"
    }

    // MARK: - Saving to disk
    // Templates live in a JSON file in the app's Documents folder. Only raw strokes
    // are written (Point leaves out `stroke`), so the format matches the web version.

    private var templatesURL: URL {
        URL.documentsDirectory.appending(path: "templates.json")
    }

    private func loadTemplates() {
        guard let data = try? Data(contentsOf: templatesURL),
              let saved = try? JSONDecoder().decode([Template].self, from: data) else { return }
        templates = saved
        prepared = saved.map(PreparedTemplate.init)    // normalize each one once, at startup
    }

    private func persistTemplates() {
        do {
            let data = try JSONEncoder().encode(templates)
            try data.write(to: templatesURL, options: .atomic)
        } catch {
            status = "Couldn't save templates: \(error.localizedDescription)"
        }
    }
}

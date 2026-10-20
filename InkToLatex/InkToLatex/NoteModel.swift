// The app's state and logic: templates (teach mode), grouping strokes into
// symbols, and building the LaTeX. This is the Swift version of the non-drawing
// half of app.js. The screen lives in ContentView; the ink lives in InkCanvas.

import Foundation
import Observation

/// One recognized symbol on the page: its strokes, its LaTeX label, and where it sits.
struct Symbol {
    var strokes: [[Point]]
    var label: String
    var x: Double          // left edge
    var top: Double = 0    // highest point (y grows downward)
    var bottom: Double = 0 // lowest point

    var centerY: Double { (top + bottom) / 2 }
}

@Observable
final class NoteModel {
    // Templates: raw ones are saved; prepared ones (normalized once) are used for matching.
    private(set) var templates: [Template] = []      // YOUR templates (saved to disk)
    private var starterCount = 0                     // built-in templates from the dataset
    // Everything the recognizer compares against: the built-in starter templates first,
    // then yours. (Yours go last, so "Undo Save" can just remove the last one.)
    private var prepared: [PreparedTemplate] = []

    // What's on the page right now
    private(set) var symbols: [Symbol] = []
    private var allStrokes: [[Point]] = []   // everything drawn since the last Erase (used by Save)
    private var lastPenUp: TimeInterval = 0

    // Results we've already worked out, so replaying the page (after undo, redo or
    // erasing) doesn't re-recognize symbols that didn't change.
    private var recognitionCache: [String: [Match]] = [:]

    var status = ""

    // Grouping rule: when does a new stroke belong to the symbol before it?
    let groupTime: TimeInterval = 1.0   // it must start within 1 s of the last pen-up,
    let minOverlap = 0.25               // overlap at least 25% of the narrower one's width,
    let joinScoreLimit = 1.5            // and together they must look like a real symbol
                                        // (best score below this; lower = closer match)

    // MARK: - Reading the page: lines, then the document

    /// Every line gets at least this much height, so a line that starts with a flat
    /// symbol like "-" still catches the digits written next to it.
    let minLineHeight = 30.0

    /// The symbols grouped into lines, top to bottom; each line reads left to right.
    ///
    /// Sort the symbols by their vertical center. Walking down the page, a symbol joins
    /// the current line if its center falls inside that line's vertical band (from its
    /// highest top to its lowest bottom); otherwise it starts a new line. It's the same
    /// idea as grouping strokes into symbols, one level up.
    var lines: [[Symbol]] {
        let topToBottom = symbols.sorted { $0.centerY < $1.centerY }

        var result: [[Symbol]] = []
        var bandTop = 0.0
        var bandBottom = 0.0

        for symbol in topToBottom {
            if !result.isEmpty && symbol.centerY >= bandTop && symbol.centerY <= bandBottom {
                result[result.count - 1].append(symbol)       // same line: widen the band
                bandTop = min(bandTop, symbol.top)
                bandBottom = max(bandBottom, symbol.bottom)
            } else {
                result.append([symbol])                       // a new line starts here
                let half = max(symbol.bottom - symbol.top, minLineHeight) / 2
                bandTop = min(symbol.top, symbol.centerY - half)
                bandBottom = max(symbol.bottom, symbol.centerY + half)
            }
        }
        return result.map { line in line.sorted { $0.x < $1.x } }
    }

    /// Each line as LaTeX: its labels, left to right, joined with spaces.
    var lineLatex: [String] {
        lines.map { line in line.map { $0.label }.joined(separator: " ") }
    }

    /// The whole page as a complete LaTeX document, one display equation per line.
    /// This is what Copy copies; paste it into Overleaf and it compiles as is.
    var document: String {
        let body = lineLatex.map { "\\[ \($0) \\]" }.joined(separator: "\n\n")
        return """
        \\documentclass{article}
        \\usepackage{amsmath, amssymb}
        \\begin{document}

        \(body)

        \\end{document}
        """
    }

    init() {
        loadStarterTemplates()
        loadTemplates()
        status = "\(templates.count) of your templates + \(starterCount) built-in"
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

        if let last = symbols.indices.last, quick,
           overlapsX(symbols[last].strokes, [points]),
           looksLikeOneSymbol(symbols[last].strokes + [points]) {
            symbols[last].strokes.append(points)          // same symbol: add this stroke
            relabel(last)
        } else {
            symbols.append(Symbol(strokes: [points], label: "", x: 0))   // a new symbol
            relabel(symbols.count - 1)
        }
    }

    /// (Re)recognize one symbol, so a "-" becomes a "+" once its second line arrives.
    private func relabel(_ index: Int) {
        let strokes = symbols[index].strokes
        symbols[index].label = results(for: strokes).first?.label ?? "?"
        symbols[index].x = xRange(strokes).min
        let ys = yRange(strokes)
        symbols[index].top = ys.min
        symbols[index].bottom = ys.max
    }

    /// Recognize some strokes, reusing the answer if we've seen these exact strokes before.
    private func results(for strokes: [[Point]]) -> [Match] {
        let key = cacheKey(strokes)
        if let cached = recognitionCache[key] { return cached }

        let fresh = recognize(strokes, templates: prepared)
        if recognitionCache.count > 2000 { recognitionCache.removeAll() }   // keep it small
        recognitionCache[key] = fresh
        print(fresh.prefix(3).map { "\($0.label): \(String(format: "%.3f", $0.score))" })
        return fresh
    }

    /// A short fingerprint of a symbol's strokes: where each stroke starts and ends,
    /// rounded to whole points so tiny adjustments don't count as a different symbol.
    private func cacheKey(_ strokes: [[Point]]) -> String {
        strokes.map { stroke in
            guard let first = stroke.first, let last = stroke.last else { return "-" }
            return "\(Int(first.x.rounded())),\(Int(first.y.rounded()))>\(Int(last.x.rounded())),\(Int(last.y.rounded()))"
        }
        .joined(separator: ";")
    }

    /// Forget everything on the page (the canvas clears itself separately).
    func clearPage() {
        allStrokes = []
        symbols = []
        lastPenUp = 0
    }

    /// Undo/redo changed strokes that were already recognized. Rather than patching
    /// things up, start over and replay every stroke on the page, in order, through the
    /// same grouping and recognition as when they were first written.
    func replaceStrokes(_ strokes: [StrokeInfo]) {
        clearPage()
        for stroke in strokes {
            strokeFinished(stroke.points, startTime: stroke.start, endTime: stroke.end)
        }
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

    /// Do two sets of strokes really overlap left to right? The shared stretch must be at
    /// least `minOverlap` of the narrower one's width. (A thin vertical line counts as
    /// about 6 points wide, so the upright of a "+" still overlaps its crossbar.)
    private func yRange(_ strokeList: [[Point]]) -> (min: Double, max: Double) {
        var minY = Double.infinity, maxY = -Double.infinity
        for stroke in strokeList {
            for p in stroke {
                minY = min(minY, p.y)
                maxY = max(maxY, p.y)
            }
        }
        return (minY, maxY)
    }

    private func overlapsX(_ a: [[Point]], _ b: [[Point]]) -> Bool {
        let ra = xRange(a)
        let rb = xRange(b)
        let shared = min(ra.max, rb.max) - max(ra.min, rb.min)
        let narrower = max(min(ra.max - ra.min, rb.max - rb.min), 6)
        return shared >= minOverlap * narrower
    }

    /// Ask the recognizer: do these strokes, taken together, match some symbol well?
    /// If not, they're probably neighbouring symbols that happen to overlap a little.
    private func looksLikeOneSymbol(_ strokes: [[Point]]) -> Bool {
        let best = results(for: strokes).first      // cached, so relabel won't redo this
        return (best?.score ?? .infinity) < joinScoreLimit
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
        recognitionCache.removeAll()                  // results may change with a new template
        persistTemplates()
        status = "Saved \"\(label)\" (\(templates.count) total)"
        return true
    }

    func undoTemplate() {
        guard let removed = templates.popLast() else { status = "No templates to undo"; return }
        prepared.removeLast()
        recognitionCache.removeAll()
        persistTemplates()
        status = "Removed \"\(removed.label)\" (\(templates.count) total)"
    }

    // MARK: - Saving to disk
    // Templates live in a JSON file in the app's Documents folder. Only raw strokes
    // are written (Point leaves out `stroke`), so the format matches the web version.

    private var templatesURL: URL {
        URL.documentsDirectory.appending(path: "templates.json")
    }

    /// The built-in templates (tools/convert.swift made them from the HWRT dataset).
    /// They ship inside the app, so a fresh install already recognizes digits, operators,
    /// letters and Greek. They're never saved or undone; only your own templates are.
    private func loadStarterTemplates() {
        guard let url = Bundle.main.url(forResource: "StarterTemplates", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let starters = try? JSONDecoder().decode([Template].self, from: data) else {
            print("No StarterTemplates.json in the app: run tools/convert.swift")
            return
        }
        starterCount = starters.count
        prepared = starters.map(PreparedTemplate.init)   // normalize each one once, at startup
    }

    private func loadTemplates() {
        guard let data = try? Data(contentsOf: templatesURL),
              let saved = try? JSONDecoder().decode([Template].self, from: data) else { return }
        templates = saved
        prepared += saved.map(PreparedTemplate.init)     // yours go after the starters
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

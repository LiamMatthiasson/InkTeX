// The app's state and logic: templates (teach mode), grouping strokes into
// symbols, and building the LaTeX. This is the Swift version of the non-drawing
// half of app.js. The screen lives in ContentView; the ink lives in InkCanvas.

import Foundation
import Observation

/// One recognized symbol on the page: its strokes, its LaTeX label, and where it sits.
struct Symbol {
    var id = UUID()        // stays the same as strokes are added, so a correction finds it
    var strokes: [[Point]]
    var label: String
    var x: Double          // left edge
    var right: Double = 0  // right edge
    var top: Double = 0    // highest point (y grows downward)
    var bottom: Double = 0 // lowest point
    var guesses: [Match] = []   // the recognizer's ranked guesses (Layout.swift may re-rank them)
    var role: ScriptRole = .normal   // superscript/subscript? (set in Layout.swift)
    var centerY: Double { (top + bottom) / 2 }
    var height: Double { bottom - top }
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
    private var lastPenUp: TimeInterval = 0
    private var replaying = false            // true while replaceStrokes replays the page

    /// Print the page and grouping decisions to Xcode's console after every stroke.
    /// Handy while tuning; turn off when you're done (it also costs a little speed).
    let debugLogging = true

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

    /// The symbols grouped into lines, top to bottom; each line reads left to right,
    /// with its scripts found and look-alikes re-ranked. (All the logic is in Layout.swift.)
    var lines: [[Symbol]] {
        groupIntoLines(symbols).map { applySpatialContext($0) }
    }

    /// Each line as LaTeX, scripts and all: "x^{2} + 1".
    var lineLatex: [String] {
        lines.map { latex(for: $0) }
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

        guard !prepared.isEmpty else { return }   // nothing to recognize against yet

        // Does this stroke belong to the symbol written just before it?
        // Yes if it started soon after the last stroke AND overlaps it left to right.
        let quick = startTime - lastPenUp < groupTime
        lastPenUp = endTime

        // Strokes that CROSS (the two lines of a slow "+" or "x") belong together however
        // long you paused; the 1-second rule is for strokes that don't touch, like "=".
        if let last = symbols.indices.last,
           quick || overlapsY(symbols[last].strokes, [points]),
           overlapsX(symbols[last].strokes, [points]),
           looksLikeOneSymbol(symbols[last].strokes + [points]) {
            symbols[last].strokes.append(points)          // same symbol: add this stroke
            relabel(last)
        } else {
            if debugLogging, !replaying, let last = symbols.indices.last {
                // Why didn't this stroke join the symbol before it? (For debugging grouping;
                // remove once grouping behaves. It recognizes the pair, so it costs a little.)
                let prev = symbols[last].strokes
                let together = results(for: prev + [points]).first
                let togetherText = together.map { "\($0.label) \(String(format: "%.2f", $0.score))" } ?? "-"
                print("  new symbol: quick \(quick), sharesHeight \(overlapsY(prev, [points])), overlapsX \(overlapsX(prev, [points])), together \(togetherText) (joins below \(joinScoreLimit))")
            }
            symbols.append(Symbol(strokes: [points], label: "", x: 0))   // a new symbol
            relabel(symbols.count - 1)
        }
        if debugLogging, !replaying { printLayout() }
    }

    /// Prints how the page was read, line by line, to Xcode's console: each symbol's
    /// label, role (^ or _), box, and the recognizer's top 3 guesses. When the LaTeX
    /// is wrong, this shows WHICH step went wrong: grouping, recognizing, or layout.
    func printLayout() {
        print("==== page ====")
        for (n, line) in lines.enumerated() {
            print("line \(n + 1): \(latex(for: line))")
            for s in line {
                let role = s.role == .sup ? "^" : s.role == .sub ? "_" : " "
                let box = String(format: "x %.0f–%.0f  y %.0f–%.0f  h %.0f", s.x, s.right, s.top, s.bottom, s.height)
                let top3 = s.guesses.prefix(3).map { "\($0.label) \(String(format: "%.2f", $0.score))" }
                print("  \(role) \(s.label.padding(toLength: 8, withPad: " ", startingAt: 0)) \(box)   [\(top3.joined(separator: ", "))]")
            }
        }
    }

    /// (Re)recognize one symbol, so a "-" becomes a "+" once its second line arrives.
    private func relabel(_ index: Int) {
        let strokes = symbols[index].strokes
        let guesses = results(for: strokes)
        symbols[index].guesses = Array(guesses.prefix(5))
        symbols[index].label = guesses.first?.label ?? "?"
        let xs = xRange(strokes)
        symbols[index].x = xs.min
        symbols[index].right = xs.max
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
        symbols = []
        lastPenUp = 0
    }

    /// Undo/redo changed strokes that were already recognized. Rather than patching
    /// things up, start over and replay every stroke on the page, in order, through the
    /// same grouping and recognition as when they were first written.
    func replaceStrokes(_ strokes: [StrokeInfo]) {
        clearPage()
        replaying = true                     // don't print the page after every stroke
        for stroke in strokes {
            strokeFinished(stroke.points, startTime: stroke.start, endTime: stroke.end)
        }
        replaying = false
        if debugLogging { printLayout() }
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

    /// Do two sets of strokes share their vertical space? The shared stretch must be at
    /// least half of the shorter one's height. True for the two lines of a "+" (the "-" is
    /// inside the "|"'s height); false for the two lines of an "=", which sit one above
    /// the other.
    private func overlapsY(_ a: [[Point]], _ b: [[Point]]) -> Bool {
        let ra = yRange(a)
        let rb = yRange(b)
        let shared = min(ra.max, rb.max) - max(ra.min, rb.min)
        let shorter = min(ra.max - ra.min, rb.max - rb.min)
        return shared >= 0 && shared >= 0.5 * shorter
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
    /// Teach: saves the LAST symbol you wrote as a template with this label, and leaves
    /// the ink where it is (it's part of your note now). Write a symbol, type what it
    /// should be, tap Teach, and it's re-read with the new template.
    func saveTemplate(label: String) -> Bool {
        guard let last = symbols.indices.last else { status = "Write a symbol first"; return false }
        return teach(last, label: label)
    }

    /// Correct: a symbol picked in the LaTeX panel is really `label`. Same as Teach, for
    /// any symbol on the page, and it records what the recognizer had said.
    func correct(_ symbolID: UUID, to label: String) {
        guard let i = symbols.firstIndex(where: { $0.id == symbolID }) else { return }
        _ = teach(i, label: label)
    }

    /// Saves symbol i's strokes as a template for `label`, then re-reads that symbol.
    private func teach(_ i: Int, label rawLabel: String) -> Bool {
        let label = rawLabel.trimmingCharacters(in: .whitespaces)   // the label is the LaTeX
        guard !label.isEmpty else { status = "Type a label first"; return false }

        let wasGuessed = symbols[i].guesses.first?.label
        let template = Template(label: label, strokes: symbols[i].strokes,
                                guessed: wasGuessed == label ? nil : wasGuessed)
        templates.append(template)
        prepared.append(PreparedTemplate(template))   // normalized once, right now
        recognitionCache.removeAll()                  // results may change with a new template
        persistTemplates()
        relabel(i)                                    // re-read it: now it matches exactly
        if let wrong = template.guessed {
            status = "Learned \"\(label)\" (it read \"\(wrong)\")"
        } else {
            status = "Taught \"\(label)\" (\(templates.count) of yours)"
        }
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
        prepared = starters.map { PreparedTemplate($0) }   // normalize each one once, at startup
    }

    private func loadTemplates() {
        guard let data = try? Data(contentsOf: templatesURL),
              let saved = try? JSONDecoder().decode([Template].self, from: data) else { return }
        templates = saved
        prepared += saved.map { PreparedTemplate($0) }  // yours go after the starters
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

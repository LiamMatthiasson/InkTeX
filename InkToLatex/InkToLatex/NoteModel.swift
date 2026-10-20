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
    var children: [Symbol] = []      // a fraction: the symbols it was built from (else empty)
    var centerY: Double { (top + bottom) / 2 }
    var height: Double { bottom - top }
}

/// Cleans up a template label: it's the LaTeX for the symbol ITSELF. "^2", "_0" and
/// "^{2}" all become "2", because whether a symbol is raised or lowered is worked out
/// from where you write it (Layout.swift). A template labelled "^2" would be read as a
/// strange symbol called "^2", and the exponent would never be detected.
func cleanLabel(_ raw: String) -> String {
    var label = raw.trimmingCharacters(in: .whitespaces)
    while let first = label.first, first == "^" || first == "_" {
        label.removeFirst()
        label = label.trimmingCharacters(in: .whitespaces)
    }
    if label.count > 2, label.hasPrefix("{"), label.hasSuffix("}") {
        label = String(label.dropFirst().dropLast())       // "{2}" → "2"
    }
    return label
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
    /// with fractions built, scripts found and look-alikes re-ranked (Layout.swift).
    /// Symbols still waiting for the recognizer (no label yet) are left out.
    var lines: [[Symbol]] {
        let ready = symbols.filter { !$0.label.isEmpty }
        return groupIntoLines(combineFractions(ready)).map { applySpatialContext($0) }
    }

    /// The page as a document: lines with words become paragraphs (text with inline
    /// math), lines without become display equations. Lines of text written one under
    /// the other join into one paragraph; a bigger vertical gap starts a new one.
    var docBlocks: [DocBlock] {
        let allLines = lines
        let typical = median(symbols.map { $0.height })
        var blocks: [DocBlock] = []
        var previousBottom: Double? = nil

        for line in allLines {
            let top = line.map { $0.top }.min() ?? 0
            let bottom = line.map { $0.bottom }.max() ?? 0
            let closeToPrevious = previousBottom.map { top - $0 < 1.2 * typical } ?? false
            previousBottom = bottom

            guard let lineParts = parts(of: line) else {
                blocks.append(.display(latex(for: line)))       // math on its own
                continue
            }
            if closeToPrevious, case .paragraph(let earlier)? = blocks.last {
                blocks[blocks.count - 1] = .paragraph(earlier + lineParts)   // same paragraph
            } else {
                blocks.append(.paragraph(lineParts))
            }
        }
        return blocks
    }

    /// The whole page as a complete LaTeX document. This is what Copy copies; it
    /// compiles as is.
    var document: String {
        let body = docBlocks.map { block in
            switch block {
            case .display(let latex):
                "\\[ \(latex) \\]"
            case .paragraph(let parts):
                parts.map { part in
                    switch part {
                    case .text(let text): escapeForLaTeX(text)
                    case .math(let latex): "$\(latex)$"
                    }
                }
                .joined(separator: " ")
            }
        }
        .joined(separator: "\n\n")
        return """
        \\documentclass{article}
        \\usepackage{amsmath, amssymb}
        \\begin{document}

        \(body)

        \\end{document}
        """
    }

    // MARK: - Text or math? (Apple's Vision reads each line as handwriting too)

    /// What Vision read for each line, by the line's ink (so an unchanged line isn't
    /// read twice).
    private(set) var textReadings: [String: TextReading] = [:]
    private var readingsInFlight: Set<String> = []
    /// Lines you've told the app to read as math or text (by the line's first symbol).
    private var kindOverrides: [UUID: LineKind] = [:]

    /// A line's text and inline-math parts, or nil if it's a display equation.
    func parts(of line: [Symbol]) -> [DocPart]? {
        let forced = firstSymbolID(line).flatMap { kindOverrides[$0] }
        if forced == .math { return nil }
        guard let reading = textReading(of: line) else { return nil }    // not read yet
        if forced == .text { return [.text(reading.text)] }
        return mixParts(line, reading)
    }

    func kind(of line: [Symbol]) -> LineKind {
        parts(of: line) == nil ? .math : .text
    }

    func textReading(of line: [Symbol]) -> TextReading? {
        textReadings[cacheKey(line.flatMap { $0.strokes })]
    }

    /// Force a line to be math or text (nil: let the app decide again).
    func setKind(_ kind: LineKind?, for line: [Symbol]) {
        guard let id = firstSymbolID(line) else { return }
        kindOverrides[id] = kind
    }

    private func firstSymbolID(_ line: [Symbol]) -> UUID? {
        line.flatMap { $0.children.isEmpty ? [$0] : $0.children }.first?.id
    }

    /// Ask Vision to read every line it hasn't read yet, in the background.
    private func readTextLines() {
        for line in lines {
            let strokes = line.flatMap { $0.strokes }
            let key = cacheKey(strokes)
            guard textReadings[key] == nil, !readingsInFlight.contains(key) else { continue }
            readingsInFlight.insert(key)
            let letterHeight = median(line.map { $0.height })
            Task {
                let reading = await Task.detached(priority: .utility) {
                    readHandwriting(strokes, letterHeight: letterHeight)    // off the main thread
                }.value
                readingsInFlight.remove(key)
                if textReadings.count > 500 { textReadings.removeAll() }   // keep it small
                textReadings[key] = reading
                if debugLogging, readingsInFlight.isEmpty { printLayout() }   // now with Vision
            }
        }
    }

    init() {
        loadStarterTemplates()
        loadTemplates()
        status = "\(templates.count) of your templates + \(starterCount) built-in"
        if labelsFixedAtLaunch > 0 {
            status += " (fixed \(labelsFixedAtLaunch) label\(labelsFixedAtLaunch == 1 ? "" : "s") that started with ^ or _)"
        }
    }

    // MARK: - Strokes: a queue, worked through one at a time
    //
    // Recognition runs in the background, so the next stroke can arrive before the last
    // one is recognized. Grouping needs strokes handled IN ORDER (is this stroke part of
    // the symbol before it?), so strokes wait in a queue and one worker takes them one
    // at a time: like a Kotlin Channel with a single consumer coroutine. The worker runs
    // on the main actor; only `recognize` itself goes to a background thread.

    private struct StrokeEvent {
        let points: [Point]
        let start: TimeInterval
        let end: TimeInterval
    }
    private var pending: [StrokeEvent] = []   // strokes waiting their turn, oldest first
    private var working = false               // is the worker running?
    /// Bumped whenever the page is cleared. Work that started before the bump notices
    /// after its `await` (the page changed while it waited) and throws its result away.
    private var generation = 0

    /// Called by the canvas each time the pen lifts.
    func strokeFinished(_ points: [Point], startTime: TimeInterval, endTime: TimeInterval) {
        guard !points.isEmpty else { return }
        pending.append(StrokeEvent(points: points, start: startTime, end: endTime))
        startWorker()
    }

    private func startWorker() {
        guard !working else { return }     // already running: it'll get to the new stroke
        working = true
        Task {
            while !pending.isEmpty {
                let event = pending.removeFirst()
                await handle(event)
            }
            working = false
            if debugLogging { printLayout() }
            readTextLines()                 // the page settled: see which lines are text
        }
    }

    /// One stroke: join it to the symbol before it, or start a new symbol.
    private func handle(_ event: StrokeEvent) async {
        guard !prepared.isEmpty else { return }   // nothing to recognize against yet
        let gen = generation
        let points = event.points

        // Does this stroke belong to the symbol written just before it?
        let quick = event.start - lastPenUp < groupTime
        lastPenUp = event.end

        // Strokes that CROSS (the two lines of a slow "+" or "x") belong together however
        // long you paused; the 1-second rule is for strokes that don't touch, like "=".
        // A fraction bar never joins the symbol above or below it.
        if let last = symbols.indices.last,
           quick || overlapsY(symbols[last].strokes, [points]),
           overlapsX(symbols[last].strokes, [points]),
           !isFractionBarPair(symbols[last].strokes, [points]) {
            let together = await results(for: symbols[last].strokes + [points]).first
            guard gen == generation else { return }          // the page changed meanwhile
            if let together, together.score < joinScoreLimit {
                symbols[last].strokes.append(points)          // same symbol: add this stroke
                await relabel(last, generation: gen)          // (already cached: instant)
                return
            }
        }

        if debugLogging, pending.isEmpty, let last = symbols.indices.last {   // not during replays
            // Why didn't this stroke join the symbol before it? (Costs a recognition.)
            let prev = symbols[last].strokes
            let together = await results(for: prev + [points]).first
            guard gen == generation else { return }
            let togetherText = together.map { "\($0.label) \(String(format: "%.2f", $0.score))" } ?? "-"
            print("  new symbol: quick \(quick), sharesHeight \(overlapsY(prev, [points])), overlapsX \(overlapsX(prev, [points])), bar \(isFractionBarPair(prev, [points])), together \(togetherText) (joins below \(joinScoreLimit))")
        }
        symbols.append(Symbol(strokes: [points], label: "", x: 0))   // a new symbol
        await relabel(symbols.count - 1, generation: gen)
    }

    /// Prints how the page was read, line by line, to Xcode's console: each symbol's
    /// label, role (^ or _), box, and the recognizer's top 3 guesses. When the LaTeX
    /// is wrong, this shows WHICH step went wrong: grouping, recognizing, or layout.
    func printLayout() {
        print("==== page ====")
        for (n, line) in lines.enumerated() {
            print("line \(n + 1): \(latex(for: line))")
            if let reading = textReading(of: line) {
                let words = reading.words.map { "\($0.text)\(looksLikeWord($0) ? "✓" : "")" }
                print("  Vision (\(String(format: "%.2f", reading.confidence))): \(words.joined(separator: " "))   → \(kind(of: line) == .text ? "text" : "math")")
            }
            for s in line {
                let role = s.role == .sup ? "^" : s.role == .sub ? "_" : " "
                let box = String(format: "x %.0f–%.0f  y %.0f–%.0f  h %.0f", s.x, s.right, s.top, s.bottom, s.height)
                let top3 = s.guesses.prefix(3).map { "\($0.label) \(String(format: "%.2f", $0.score))" }
                print("  \(role) \(s.label.padding(toLength: 8, withPad: " ", startingAt: 0)) \(box)   [\(top3.joined(separator: ", "))]")
            }
        }
    }

    /// (Re)recognize one symbol, so a "-" becomes a "+" once its second line arrives.
    private func relabel(_ index: Int, generation gen: Int) async {
        guard gen == generation, symbols.indices.contains(index) else { return }  // page cleared
        let id = symbols[index].id
        let strokes = symbols[index].strokes
        let guesses = await results(for: strokes)

        // While we waited, the page may have been cleared or this symbol grown a stroke
        // (its newer recognition will fill it in): then this result is stale.
        guard gen == generation,
              let i = symbols.firstIndex(where: { $0.id == id }),
              symbols[i].strokes.count == strokes.count else { return }

        symbols[i].guesses = Array(guesses.prefix(5))
        symbols[i].label = guesses.first?.label ?? "?"
        let xs = xRange(strokes)
        symbols[i].x = xs.min
        symbols[i].right = xs.max
        let ys = yRange(strokes)
        symbols[i].top = ys.min
        symbols[i].bottom = ys.max
    }

    /// Recognize some strokes in the background, reusing the answer if we've seen these
    /// exact strokes before.
    private func results(for strokes: [[Point]]) async -> [Match] {
        let key = cacheKey(strokes)
        if let cached = recognitionCache[key] { return cached }

        // Arrays are values: the background task gets its own copy of the templates, so
        // nothing is shared between threads. (Swift only copies if one side changes it.)
        let templates = prepared
        let fresh = await Task.detached(priority: .userInitiated) {
            recognize(strokes, templates: templates)                // off the main thread
        }.value

        if recognitionCache.count > 2000 { recognitionCache.removeAll() }   // keep it small
        recognitionCache[key] = fresh
        if debugLogging {
            print(fresh.prefix(3).map { "\($0.label): \(String(format: "%.3f", $0.score))" })
        }
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
        generation += 1          // anything still being recognized is for the old page
        pending = []
        symbols = []
        lastPenUp = 0
    }

    /// Undo/redo/opening a note changed strokes that were already recognized. Rather than
    /// patching things up, start over: queue every stroke on the page, in order, through
    /// the same grouping and recognition as when they were first written.
    func replaceStrokes(_ strokes: [StrokeInfo]) {
        clearPage()
        pending = strokes.map { StrokeEvent(points: $0.points, start: $0.start, end: $0.end) }
        startWorker()
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

    /// A fraction bar never joins the symbol above or below it (a "2" with a bar under it
    /// isn't a "z"). A bar: one flat stroke, much wider than the other piece, which sits
    /// entirely above or below it. A "+" doesn't count (its "|" crosses the "-"), nor do
    /// the dots of a "÷" (too small).
    private func isFractionBarPair(_ a: [[Point]], _ b: [[Point]]) -> Bool {
        func isBar(_ bar: [[Point]], beside other: [[Point]]) -> Bool {
            guard bar.count == 1 else { return false }
            let bx = xRange(bar), by = yRange(bar)
            let ox = xRange(other), oy = yRange(other)
            let barWidth = bx.max - bx.min
            let otherWidth = ox.max - ox.min
            let otherSize = max(otherWidth, oy.max - oy.min)
            let flat = by.max - by.min < 0.25 * barWidth
            let wider = barWidth > 1.5 * otherWidth
            let notADot = otherSize >= 0.25 * barWidth
            let barY = (by.min + by.max) / 2
            let aboveOrBelow = oy.max <= barY || oy.min >= barY      // doesn't cross it
            return flat && wider && notADot && aboveOrBelow
        }
        return isBar(b, beside: a) || isBar(a, beside: b)
    }

    private func overlapsX(_ a: [[Point]], _ b: [[Point]]) -> Bool {
        let ra = xRange(a)
        let rb = xRange(b)
        let shared = min(ra.max, rb.max) - max(ra.min, rb.min)
        let narrower = max(min(ra.max - ra.min, rb.max - rb.min), 6)
        return shared >= minOverlap * narrower
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
        let label = cleanLabel(rawLabel)                    // the label is the LaTeX, no ^ or _
        guard !label.isEmpty else { status = "Type a label first"; return false }
        let wasCleaned = label != rawLabel.trimmingCharacters(in: .whitespaces)

        let wasGuessed = symbols[i].guesses.first?.label
        let template = Template(label: label, strokes: symbols[i].strokes,
                                guessed: wasGuessed == label ? nil : wasGuessed)
        templates.append(template)
        prepared.append(PreparedTemplate(template))   // normalized once, right now
        recognitionCache.removeAll()                  // results may change with a new template
        persistTemplates()
        let gen = generation
        Task { await relabel(i, generation: gen) }    // re-read it: now it matches exactly
        if wasCleaned {
            status = "Saved as \"\(label)\": no ^ or _ needed, raised/lowered comes from where you write it"
        } else if let wrong = template.guessed {
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

    /// Deletes one of your templates (any of them, from the Templates list).
    func deleteTemplate(at i: Int) {
        guard templates.indices.contains(i) else { return }
        let removed = templates.remove(at: i)
        prepared.remove(at: starterCount + i)          // same position after the starters
        recognitionCache.removeAll()                   // results may change without it
        persistTemplates()
        rereadPage()
        status = "Deleted a \"\(removed.label)\" template (\(templates.count) of yours left)"
    }

    /// Gives one of your templates a different label (fixing a typo, say).
    func renameTemplate(at i: Int, to rawLabel: String) {
        let label = cleanLabel(rawLabel)
        guard templates.indices.contains(i), !label.isEmpty else { return }
        let old = templates[i].label
        templates[i].label = label
        prepared[starterCount + i] = PreparedTemplate(templates[i])
        recognitionCache.removeAll()
        persistTemplates()
        rereadPage()
        status = "Changed a template from \"\(old)\" to \"\(label)\""
    }

    /// Re-recognize every symbol on the page (after templates changed), in the background.
    private func rereadPage() {
        let gen = generation
        let count = symbols.count
        Task {
            for i in 0..<count {
                await relabel(i, generation: gen)
            }
        }
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
        // Templates saved before the label guard existed may say "^2": fix them now
        var cleaned = saved
        for i in cleaned.indices {
            let label = cleanLabel(cleaned[i].label)
            if label != cleaned[i].label, !label.isEmpty {
                print("Fixed a template label: \"\(cleaned[i].label)\" → \"\(label)\"")
                cleaned[i].label = label
                labelsFixedAtLaunch += 1
            }
        }
        templates = cleaned
        prepared += cleaned.map { PreparedTemplate($0) }  // yours go after the starters
        if labelsFixedAtLaunch > 0 { persistTemplates() }
    }

    private var labelsFixedAtLaunch = 0

    private func persistTemplates() {
        do {
            let data = try JSONEncoder().encode(templates)
            try data.write(to: templatesURL, options: .atomic)
        } catch {
            status = "Couldn't save templates: \(error.localizedDescription)"
        }
    }
}

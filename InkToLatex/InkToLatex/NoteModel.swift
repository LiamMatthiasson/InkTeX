// The app's state and logic: templates, grouping strokes into symbols, and building
// the LaTeX document. The screen is ContentView; the ink is InkCanvas.

import Foundation
import Observation

/// One recognized symbol on the page: its strokes, its LaTeX label, and where it sits.
struct Symbol {
    var id = UUID()        // stable as strokes are added, so a correction finds it
    var strokes: [[Point]]
    var label: String
    var x: Double          // left edge
    var right: Double = 0
    var top: Double = 0    // y grows downward
    var bottom: Double = 0
    var guesses: [Match] = []
    var role: ScriptRole = .normal   // set in Layout.swift
    var children: [Symbol] = []      // a fraction's pieces (else empty)
    var centerY: Double { (top + bottom) / 2 }
    var height: Double { bottom - top }
}

/// A label is the symbol ITSELF: "^2", "_0" and "^{2}" all become "2". Raised or
/// lowered comes from where it's written (Layout.swift).
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
    private(set) var templates: [Template] = []      // yours (saved to disk)
    private var starterCount = 0
    // What the recognizer compares against: starters first, then yours (so Undo Teach
    // can remove the last one).
    private var prepared: [PreparedTemplate] = []

    private(set) var symbols: [Symbol] = []
    private var lastPenUp: TimeInterval = 0

    /// Prints the page and grouping decisions to the console. Turn off when done tuning.
    let debugLogging = true

    // So replaying the page after undo/redo/erase doesn't re-recognize unchanged symbols
    private var recognitionCache: [String: [Match]] = [:]

    var status = ""

    // A new stroke joins the symbol before it if it starts within groupTime of the last
    // pen-up, overlaps by minOverlap of the narrower width, and together they score
    // below joinScoreLimit.
    let groupTime: TimeInterval = 1.0
    let minOverlap = 0.25
    let joinScoreLimit = 1.5

    // MARK: - Reading the page: lines, then the document

    /// Lines top to bottom, each left to right, with fractions, scripts and re-ranking
    /// applied. Symbols not recognized yet are left out.
    var lines: [[Symbol]] {
        let ready = symbols.filter { !$0.label.isEmpty }
        return groupIntoLines(combineStructures(ready)).map { applySpatialContext($0) }
    }

    /// Lines with words become paragraphs (close lines merge); the rest become display
    /// equations.
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
                blocks.append(.display(latex(for: line)))
                continue
            }
            if closeToPrevious, case .paragraph(let earlier)? = blocks.last {
                blocks[blocks.count - 1] = .paragraph(earlier + lineParts)
            } else {
                blocks.append(.paragraph(lineParts))
            }
        }
        return blocks
    }

    /// The complete, compilable document that Copy copies.
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

    // MARK: - Text or math? (Vision reads each line as handwriting too)

    private(set) var textReadings: [String: TextReading] = [:]   // keyed by the line's ink
    private var readingsInFlight: Set<String> = []
    private var kindOverrides: [UUID: LineKind] = [:]            // keyed by the line's first symbol

    /// A line's text and inline-math parts, or nil if it's a display equation.
    func parts(of line: [Symbol]) -> [DocPart]? {
        let forced = firstSymbolID(line).flatMap { kindOverrides[$0] }
        if forced == .math { return nil }
        guard let reading = textReading(of: line) else { return nil }
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

    /// Reads every not-yet-read line with Vision, in the background.
    private func readTextLines() {
        for line in lines {
            let strokes = line.flatMap { $0.strokes }
            let key = cacheKey(strokes)
            guard textReadings[key] == nil, !readingsInFlight.contains(key) else { continue }
            readingsInFlight.insert(key)
            let letterHeight = median(line.map { $0.height })
            Task {
                let reading = await Task.detached(priority: .utility) {
                    readHandwriting(strokes, letterHeight: letterHeight)
                }.value
                readingsInFlight.remove(key)
                if textReadings.count > 500 { textReadings.removeAll() }
                textReadings[key] = reading
                if debugLogging, readingsInFlight.isEmpty { printLayout() }
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
    // Grouping needs strokes IN ORDER, but recognition is async, so strokes wait in a
    // queue for a single worker (like a Kotlin Channel with one consumer). Only
    // `recognize` itself runs off the main actor.

    private struct StrokeEvent {
        let points: [Point]
        let start: TimeInterval
        let end: TimeInterval
    }
    private var pending: [StrokeEvent] = []
    private var working = false
    /// Bumped when the page is cleared; work resuming after an `await` checks it and
    /// drops stale results.
    private var generation = 0

    func strokeFinished(_ points: [Point], startTime: TimeInterval, endTime: TimeInterval) {
        guard !points.isEmpty else { return }
        pending.append(StrokeEvent(points: points, start: startTime, end: endTime))
        startWorker()
    }

    private func startWorker() {
        guard !working else { return }
        working = true
        Task {
            while !pending.isEmpty {
                let event = pending.removeFirst()
                await handle(event)
            }
            working = false
            if debugLogging { printLayout() }
            readTextLines()
        }
    }

    /// One stroke: join it to the symbol before it, or start a new symbol.
    private func handle(_ event: StrokeEvent) async {
        guard !prepared.isEmpty else { return }
        let gen = generation
        let points = event.points

        let quick = event.start - lastPenUp < groupTime
        lastPenUp = event.end

        // Crossing strokes (a slow "+") join however long the pause; the time rule is for
        // strokes that don't touch, like "=". A fraction bar never joins.
        if let last = symbols.indices.last,
           quick || overlapsY(symbols[last].strokes, [points]),
           overlapsX(symbols[last].strokes, [points]),
           !isFractionBarPair(symbols[last].strokes, [points]),
           !isUnderRoot(points, symbols[last]) {
            let together = await results(for: symbols[last].strokes + [points]).first
            guard gen == generation else { return }
            if let together, together.score < joinScoreLimit {
                symbols[last].strokes.append(points)
                await relabel(last, generation: gen)          // cached: instant
                return
            }
        }

        if debugLogging, pending.isEmpty, let last = symbols.indices.last {   // not during replays
            // Why didn't it join? (Costs a recognition.)
            let prev = symbols[last].strokes
            let together = await results(for: prev + [points]).first
            guard gen == generation else { return }
            let togetherText = together.map { "\($0.label) \(String(format: "%.2f", $0.score))" } ?? "-"
            print("  new symbol: quick \(quick), sharesHeight \(overlapsY(prev, [points])), overlapsX \(overlapsX(prev, [points])), bar \(isFractionBarPair(prev, [points])), underRoot \(isUnderRoot(points, symbols[last])), together \(togetherText) (joins below \(joinScoreLimit))")
        }
        symbols.append(Symbol(strokes: [points], label: "", x: 0))
        await relabel(symbols.count - 1, generation: gen)
    }

    /// Prints each line's symbols (label, role, box, top 3 guesses), to see whether
    /// grouping, recognition or layout went wrong.
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
        guard gen == generation, symbols.indices.contains(index) else { return }
        let id = symbols[index].id
        let strokes = symbols[index].strokes
        let guesses = await results(for: strokes)

        // Stale if the page was cleared or the symbol grew a stroke meanwhile
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

    /// Recognizes strokes in the background, or reuses a cached answer.
    private func results(for strokes: [[Point]]) async -> [Match] {
        let key = cacheKey(strokes)
        if let cached = recognitionCache[key] { return cached }

        // Arrays are values: the background task gets its own copy, nothing is shared
        let templates = prepared
        let fresh = await Task.detached(priority: .userInitiated) {
            recognize(strokes, templates: templates)
        }.value

        if recognitionCache.count > 2000 { recognitionCache.removeAll() }
        recognitionCache[key] = fresh
        if debugLogging {
            print(fresh.prefix(3).map { "\($0.label): \(String(format: "%.3f", $0.score))" })
        }
        return fresh
    }

    /// Each stroke's rounded start and end points.
    private func cacheKey(_ strokes: [[Point]]) -> String {
        strokes.map { stroke in
            guard let first = stroke.first, let last = stroke.last else { return "-" }
            return "\(Int(first.x.rounded())),\(Int(first.y.rounded()))>\(Int(last.x.rounded())),\(Int(last.y.rounded()))"
        }
        .joined(separator: ";")
    }

    func clearPage() {
        generation += 1
        pending = []
        symbols = []
        lastPenUp = 0
    }

    /// After undo/redo/opening a note: start over and replay every stroke in order.
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

    /// Shared height is at least half the shorter one's: true for "+", false for "=".
    private func overlapsY(_ a: [[Point]], _ b: [[Point]]) -> Bool {
        let ra = yRange(a)
        let rb = yRange(b)
        let shared = min(ra.max, rb.max) - max(ra.min, rb.min)
        let shorter = min(ra.max - ra.min, rb.max - rb.min)
        return shared >= 0 && shared >= 0.5 * shorter
    }

    /// One flat stroke, much wider than the other piece, which sits entirely above or
    /// below it (a "2" over a bar isn't a "z"). Not a "+" (crosses) or "÷" (dots too small).
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
            let aboveOrBelow = oy.max <= barY || oy.min >= barY
            return flat && wider && notADot && aboveOrBelow
        }
        return isBar(b, beside: a) || isBar(a, beside: b)
    }

    /// Shared width is at least `minOverlap` of the narrower one's (thin lines count as 6 pt).
    /// A stroke written under the hood of a √ (or in the crook of its tick, as an index)
    /// is the start of something new, never part of the √ itself: together they might
    /// even look like some other symbol. Under = middle inside the √'s box, right of the
    /// tick, and the √ much wider than the stroke.
    private func isUnderRoot(_ stroke: [Point], _ symbol: Symbol) -> Bool {
        guard symbol.label == "\\sqrt" else { return false }
        let xs = xRange([stroke]), ys = yRange([stroke])
        let width = symbol.right - symbol.x
        let centerX = (xs.min + xs.max) / 2
        let centerY = (ys.min + ys.max) / 2
        let under = centerX > symbol.x + 0.25 * width && centerX < symbol.right + 0.1 * width
            && centerY > symbol.top && centerY < symbol.bottom
            && width >= 1.5 * (xs.max - xs.min)
        // ...or small, in the crook of the tick: the index of a cube root (∛)
        let index = centerX < symbol.x + 0.35 * width
            && centerY < symbol.top + 0.6 * symbol.height
            && max(xs.max - xs.min, ys.max - ys.min) < 0.5 * symbol.height
        return under || index
    }

    private func overlapsX(_ a: [[Point]], _ b: [[Point]]) -> Bool {
        let ra = xRange(a)
        let rb = xRange(b)
        let shared = min(ra.max, rb.max) - max(ra.min, rb.min)
        let narrower = max(min(ra.max - ra.min, rb.max - rb.min), 6)
        return shared >= minOverlap * narrower
    }

    // MARK: - Templates (teach mode)

    /// Teach: saves the LAST symbol as a template and leaves the ink in place.
    func saveTemplate(label: String) -> Bool {
        guard let last = symbols.indices.last else { status = "Write a symbol first"; return false }
        return teach(last, label: label)
    }

    /// Teach for any symbol (a chip in the LaTeX panel).
    func correct(_ symbolID: UUID, to label: String) {
        guard let i = symbols.firstIndex(where: { $0.id == symbolID }) else { return }
        _ = teach(i, label: label)
    }

    /// Saves symbol i's strokes as a template for `label`, then re-reads that symbol.
    private func teach(_ i: Int, label rawLabel: String) -> Bool {
        let label = cleanLabel(rawLabel)
        guard !label.isEmpty else { status = "Type a label first"; return false }
        let wasCleaned = label != rawLabel.trimmingCharacters(in: .whitespaces)

        let wasGuessed = symbols[i].guesses.first?.label
        let template = Template(label: label, strokes: symbols[i].strokes,
                                guessed: wasGuessed == label ? nil : wasGuessed)
        templates.append(template)
        prepared.append(PreparedTemplate(template))
        recognitionCache.removeAll()
        persistTemplates()
        let gen = generation
        Task { await relabel(i, generation: gen) }
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

    func deleteTemplate(at i: Int) {
        guard templates.indices.contains(i) else { return }
        let removed = templates.remove(at: i)
        prepared.remove(at: starterCount + i)
        recognitionCache.removeAll()
        persistTemplates()
        rereadPage()
        status = "Deleted a \"\(removed.label)\" template (\(templates.count) of yours left)"
    }

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

    private func rereadPage() {
        let gen = generation
        let count = symbols.count
        Task {
            for i in 0..<count {
                await relabel(i, generation: gen)
            }
        }
    }

    // MARK: - Backing up templates

    /// Your templates as the contents of a .json file (same format as templates.json).
    func templatesBackup() -> Data {
        (try? JSONEncoder().encode(templates)) ?? Data("[]".utf8)
    }

    /// Adds the templates from a backup file. Labels are cleaned (no ^ or _), and ones
    /// you already have (same label, same ink) are skipped, so importing twice is safe.
    /// Returns what happened, for the screen.
    @discardableResult
    func importTemplates(from data: Data) -> String {
        guard let incoming = try? JSONDecoder().decode([Template].self, from: data) else {
            status = "That file isn't a templates backup"
            return status
        }
        var known = Set(templates.map { $0.label + "|" + cacheKey($0.strokes) })
        var added = 0
        for var template in incoming {
            template.label = cleanLabel(template.label)
            let key = template.label + "|" + cacheKey(template.strokes)
            guard !template.label.isEmpty, !template.strokes.isEmpty, !known.contains(key) else { continue }
            known.insert(key)
            templates.append(template)
            prepared.append(PreparedTemplate(template))   // yours always go after the starters
            added += 1
        }
        if added > 0 {
            recognitionCache.removeAll()
            persistTemplates()
            rereadPage()
        }
        let skipped = incoming.count - added
        status = "Imported \(added) template\(added == 1 ? "" : "s")"
            + (skipped > 0 ? " (\(skipped) skipped: already here or empty)" : "")
        return status
    }

    // MARK: - Saving to disk
    // Documents/templates.json, raw strokes only: the same format as the web version.

    private var templatesURL: URL {
        URL.documentsDirectory.appending(path: "templates.json")
    }

    /// Built-in templates from the HWRT dataset (tools/convert.swift). Never saved or undone.
    private func loadStarterTemplates() {
        guard let url = Bundle.main.url(forResource: "StarterTemplates", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let starters = try? JSONDecoder().decode([Template].self, from: data) else {
            print("No StarterTemplates.json in the app: run tools/convert.swift")
            return
        }
        starterCount = starters.count
        prepared = starters.map { PreparedTemplate($0) }
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
        prepared += cleaned.map { PreparedTemplate($0) }
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

// How symbols sit relative to each other: lines, fractions, scripts, and size/position
// re-ranking. Pure logic, like Recognizer.swift. normalize() throws size and position
// away; this file brings them back to break ties (g/9, s/5, x vs digits).

import Foundation

struct LineMetrics {
    let baseline: Double        // y grows downward
    let typicalHeight: Double
    let tallHeight: Double?     // nil if the line has no confident tall symbols
}

// MARK: - Median

/// The middle value of a list (the average of the two middle values if the count is even).
func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let n = sorted.count
    let isOdd = n % 2 == 1
    return isOdd ? sorted[n / 2]
                 : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
}

// MARK: - Which symbols are which

let descenders: Set<String> = ["g", "y", "p", "q", "j", "\\mu", "\\beta", "\\phi", "\\psi", "\\xi"]
/// Their bottoms say nothing about where the line is
let floaters: Set<String> = ["-", "=", "\\cdot", "\\approx", "\\sim", "+", "\\times", "\\div", "\\pm",
                             "\\equiv", "\\rightarrow", "\\Rightarrow", "\\Leftrightarrow", "\\mapsto"]
/// About half as tall as a digit
let smallLetters: Set<String> = ["a", "c", "e", "m", "n", "o", "r", "s", "u", "v", "w", "x", "z",
                                 "\\alpha", "\\omega", "\\sigma", "\\pi", "\\varepsilon", "\\tau"]
let tinySymbols: Set<String> = ["\\cdot", "."]
let tallSymbols: Set<String> = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
                                "b", "d", "f", "h", "k", "\\delta", "\\theta", "\\lambda",
                                "A", "B", "D", "E", "F", "G", "H", "L", "M", "N", "Q", "R", "T",
                                "\\Gamma", "\\Delta", "\\Theta", "\\Pi", "\\Phi", "\\Omega",
                                "\\mathbb{R}", "\\mathbb{N}", "\\mathbb{Z}", "\\mathbb{Q}", "\\mathbb{C}",
                                "\\forall", "\\exists"]

// MARK: - Measuring a line

/// The best guess is clearly ahead of the second.
func isConfident(_ symbol: Symbol) -> Bool {
    symbol.guesses.count < 2 || symbol.guesses[1].score - symbol.guesses[0].score >= unsureMargin
}

/// Measures a line from confident symbols only (a "g" misread as "9" would drag the
/// baseline down). Baseline = median bottom of non-descenders, non-floaters. Size is
/// compared against TALL symbols, since in "x + y" the typical symbol is small.
func measureLine(_ line: [Symbol]) -> LineMetrics? {
    let sitters = line.filter {
        isConfident($0) && !descenders.contains($0.label) && !floaters.contains($0.label)
            && $0.children.isEmpty      // a fraction reaches far below the line
    }
    guard !sitters.isEmpty else { return nil }

    let bottoms = sitters.map { symbol in symbol.bottom }
    let heights = sitters.map { symbol in symbol.bottom - symbol.top }

    let tall = sitters.filter { tallSymbols.contains($0.label) }
    let tallHeight: Double? = tall.isEmpty ? nil : median(tall.map { $0.bottom - $0.top })

    return LineMetrics(baseline: median(bottoms),
                       typicalHeight: median(heights),
                       tallHeight: tallHeight)
}

// MARK: - Measuring a symbol against its line

struct SymbolMeasure {
    let relativeHeight: Double?   // height ÷ tall height
    let drop: Double              // (bottom - baseline) ÷ typical height: ≈0 on the line, 0.3+ hanging
    let size: Double              // height ÷ typical height
}

func measure(_ symbol: Symbol, on line: LineMetrics) -> SymbolMeasure {
    let symbolHeight = symbol.bottom - symbol.top
    let relativeHeight = line.tallHeight.map { symbolHeight / $0 }
    let drop = (symbol.bottom - line.baseline) / line.typicalHeight
    return SymbolMeasure(relativeHeight: relativeHeight, drop: drop,
                         size: symbolHeight / line.typicalHeight)
}

// MARK: - The rules

/// Added to a guess's score per broken expectation (lower = better).
let mismatchPenalty = 0.5

func penalty(for label: String, _ m: SymbolMeasure) -> Double {
    var total = 0.0

    // Descenders hang below the line; sitters don't
    if descenders.contains(label) && m.drop < 0.15 { total += mismatchPenalty }
    if !descenders.contains(label) && !floaters.contains(label) && m.drop > 0.3 {
        total += mismatchPenalty
    }

    // Dots are tiny, and nothing else is (flat floaters exempt)
    if tinySymbols.contains(label) && m.size > 0.35 { total += mismatchPenalty }
    if !tinySymbols.contains(label) && !floaters.contains(label) && m.size < 0.15 {
        total += mismatchPenalty
    }

    if let h = m.relativeHeight {
        if smallLetters.contains(label) && h > 0.85 { total += mismatchPenalty }
        if tallSymbols.contains(label) && h < 0.65 { total += mismatchPenalty }
    }
    return total
}

// MARK: - Re-ranking

/// The top two guesses closer than this = unsure.
let unsureMargin = 0.3

/// A tie-breaker, not an override: only unsure symbols, only among their top 3.
func rerank(_ guesses: [Match], _ m: SymbolMeasure) -> [Match] {
    guard guesses.count >= 2,
          guesses[1].score - guesses[0].score < unsureMargin else { return guesses }

    let top = guesses.prefix(3).map { Match(label: $0.label, score: $0.score + penalty(for: $0.label, m)) }
    return top.sorted { $0.score < $1.score } + guesses.dropFirst(3)
}

/// findScripts → re-rank normal symbols (scripts would break the size rules) →
/// fixLoneBar → findScripts again, since re-ranking can change a label.
func applySpatialContext(_ line: [Symbol]) -> [Symbol] {
    var marked = findScripts(line)

    if let metrics = measureLine(marked.filter { $0.role == .normal }) {
        marked = marked.map { symbol in
            guard symbol.role == .normal else { return symbol }
            var adjusted = symbol
            let reranked = rerank(symbol.guesses, measure(symbol, on: metrics))
            if let best = reranked.first { adjusted.label = best.label }
            return adjusted
        }
    }
    marked = fixLoneBar(marked)
    return findScripts(marked)
}

/// "|" comes in pairs, so a lone "|" with "1" in its top 3 becomes a 1.
func fixLoneBar(_ line: [Symbol]) -> [Symbol] {
    let bars = line.indices.filter { line[$0].label == "|" }
    guard bars.count == 1, let i = bars.first,
          line[i].guesses.prefix(3).contains(where: { $0.label == "1" }) else { return line }
    var fixed = line
    fixed[i].label = "1"
    return fixed
}

// MARK: - Lines

/// How far (× line height) a small symbol may sit outside a line and still join it.
let scriptLineMargin = 0.5

struct LineBand {
    var top: Double
    var bottom: Double
    var symbols: [Symbol]
    var height: Double { bottom - top }
}

/// Lines top to bottom, each left to right. Tallest symbols go first to set up the
/// bands; a small symbol may join up to half a line-height outside one (a raised ²).
/// Min line height is the page's median symbol height, so it works at any zoom.
func groupIntoLines(_ symbols: [Symbol]) -> [[Symbol]] {
    let tallestFirst = symbols.sorted { $0.height > $1.height }
    let minLineHeight = median(symbols.map { $0.height })
    var bands: [LineBand] = []

    for symbol in tallestFirst {
        // 0 = center inside the band
        func distance(_ band: LineBand) -> Double {
            max(band.top - symbol.centerY, symbol.centerY - band.bottom, 0)
        }
        func allowed(_ band: LineBand) -> Double {
            symbol.height < 0.7 * band.height ? scriptLineMargin * band.height : 0
        }

        let closest = bands.indices
            .filter { distance(bands[$0]) <= allowed(bands[$0]) }
            .min { distance(bands[$0]) < distance(bands[$1]) }

        if let i = closest {
            let inside = distance(bands[i]) == 0
            bands[i].symbols.append(symbol)
            if inside {                       // scripts don't widen the band
                bands[i].top = min(bands[i].top, symbol.top)
                bands[i].bottom = max(bands[i].bottom, symbol.bottom)
            }
        } else {
            let half = max(symbol.height, minLineHeight) / 2
            bands.append(LineBand(top: min(symbol.top, symbol.centerY - half),
                                  bottom: max(symbol.bottom, symbol.centerY + half),
                                  symbols: [symbol]))
        }
    }
    return bands.sorted { $0.top < $1.top }
                .map { band in band.symbols.sorted { $0.x < $1.x } }
}

// MARK: - Fractions and square roots
//
// Both are CONTAINERS: other symbols belong to them by position, not by reading order.
//   fraction: a wide "-" with symbols right above AND below → \frac{above}{below}
//   root:     a √ with symbols under its hood → \sqrt{under}, and a small symbol in the
//             crook of its tick → the index: \sqrt[3]{x}
// Found on the whole page before line grouping (which would split a fraction into three
// lines), and combined into one tall Symbol whose `children` are its pieces.

/// Narrowest containers first, so nested ones are built inside out:
/// \sqrt{\frac{a}{b}} and \frac{\sqrt{x}}{2} both work.
func combineStructures(_ symbols: [Symbol]) -> [Symbol] {
    guard symbols.count >= 2 else { return symbols }
    let typical = median(symbols.map { $0.height })
    var remaining = symbols

    let containers = symbols
        .filter { isFractionBar($0, typical: typical) || isRadical($0) }
        .sorted { ($0.right - $0.x) < ($1.right - $1.x) }

    for container in containers {
        guard remaining.contains(where: { $0.id == container.id }) else { continue }
        let others = remaining.filter { $0.id != container.id }

        let found = isRadical(container)
            ? makeRoot(container, from: others)
            : makeFraction(container, from: others, typical: typical)
        guard let found else { continue }          // nothing inside it: leave it alone

        // Remove exactly the symbols it was made from (an inner fraction is ONE symbol
        // here, with its own id), and add the combined one.
        let used = Set(found.parts.map { $0.id })
        remaining = remaining.filter { !used.contains($0.id) } + [composite(found.parts, label: found.label)]
    }
    return remaining
}

/// One symbol made of several: its box covers all of them.
func composite(_ parts: [Symbol], label: String) -> Symbol {
    Symbol(
        strokes: parts.flatMap { $0.strokes },
        label: label,
        x: parts.map { $0.x }.min()!,
        right: parts.map { $0.right }.max()!,
        top: parts.map { $0.top }.min()!,
        bottom: parts.map { $0.bottom }.max()!,
        children: parts.flatMap { $0.children.isEmpty ? [$0] : $0.children }
    )
}

/// A container's pieces (the container included) and the LaTeX for all of them together.
struct Structure {
    let parts: [Symbol]
    let label: String
}

/// A bar with symbols right above and below it → \frac{…}{…}; nil if it's a plain minus.
func makeFraction(_ bar: Symbol, from others: [Symbol], typical: Double) -> Structure? {
    let barY = bar.centerY
    let slack = 0.1 * (bar.right - bar.x)

    func overBar(_ s: Symbol) -> Bool {
        let centerX = (s.x + s.right) / 2
        return centerX > bar.x - slack && centerX < bar.right + slack
    }

    var above = others.filter { overBar($0) && $0.bottom <= barY + 0.15 * typical
                                             && $0.bottom >= barY - 0.8 * typical }
    var below = others.filter { overBar($0) && $0.top >= barY - 0.15 * typical
                                             && $0.top <= barY + 0.8 * typical }
    guard !above.isEmpty, !below.isEmpty else { return nil }   // a plain minus

    // Plus whatever shares their row (the ² of an x² in the numerator)
    above += sameRow(as: above, from: others, typical: typical) { overBar($0) && $0.bottom <= barY }
    below += sameRow(as: below, from: others, typical: typical) { overBar($0) && $0.top >= barY }

    let numerator = latex(for: applySpatialContext(above.sorted { $0.x < $1.x }))
    let denominator = latex(for: applySpatialContext(below.sorted { $0.x < $1.x }))
    return Structure(parts: above + [bar] + below, label: "\\frac{\(numerator)}{\(denominator)}")
}

/// A √ with symbols under its hood → \sqrt{…} (or \sqrt[n]{…}); nil if nothing's under it
/// yet (then it stays a plain \sqrt, and LaTeX applies it to whatever comes next).
///
///      n ┌──────────        the hood: the top bar, from the tick to the right end
///      \/  x + 1            under it: middle inside the √'s height, right of the tick
///      ↑
///      the tick: the left quarter; a small symbol in its crook is the index
func makeRoot(_ root: Symbol, from others: [Symbol]) -> Structure? {
    let width = root.right - root.x
    let tickEnd = root.x + 0.25 * width

    let under = others.filter { s in
        let centerX = (s.x + s.right) / 2
        return centerX > tickEnd && centerX < root.right + 0.1 * width
            && s.centerY > root.top && s.centerY < root.bottom
            && s.height < 0.95 * root.height                // fits under the hood
    }
    guard !under.isEmpty else { return nil }
    let underIDs = Set(under.map { $0.id })

    // The index: small, its middle near the tick, sitting in the upper part of the √
    let index = others.filter { s in
        let centerX = (s.x + s.right) / 2
        return !underIDs.contains(s.id)
            && centerX > root.x - 0.3 * width && centerX < root.x + 0.35 * width
            && s.centerY > root.top - 0.1 * root.height
            && s.bottom <= root.top + 0.6 * root.height
            && s.height < 0.5 * root.height
    }

    let inside = latex(for: applySpatialContext(under.sorted { $0.x < $1.x }))
    let degree = index.isEmpty ? "" : "[" + latex(for: applySpatialContext(index.sorted { $0.x < $1.x })) + "]"
    return Structure(parts: [root] + index + under, label: "\\sqrt\(degree){\(inside)}")
}

/// A square root symbol that isn't already part of something.
func isRadical(_ symbol: Symbol) -> Bool {
    symbol.label == "\\sqrt" && symbol.children.isEmpty
}

/// A "-" at least 60% as wide as a typical symbol is tall.
func isFractionBar(_ symbol: Symbol, typical: Double) -> Bool {
    symbol.label == "-" && symbol.children.isEmpty && (symbol.right - symbol.x) >= 0.6 * typical
}

/// Symbols whose middles fall within the group's height (± half a symbol) and pass `keep`.
private func sameRow(as group: [Symbol], from pool: [Symbol], typical: Double,
                     keep: (Symbol) -> Bool) -> [Symbol] {
    let ids = Set(group.map { $0.id })
    let top = group.map { $0.top }.min()! - 0.5 * typical
    let bottom = group.map { $0.bottom }.max()! + 0.5 * typical
    return pool.filter { s in
        !ids.contains(s.id) && keep(s) && s.centerY >= top && s.centerY <= bottom
    }
}

// MARK: - Superscripts and subscripts
//
// A script is SMALLER THAN EXPECTED next to its base: the x in "2x" is small because
// small letters are; the 0 in "e₀" shrank. Up or down then picks ^ or _.

enum ScriptRole {
    case normal, sup, sub   // "subscript" is a Swift keyword
}

let brackets: Set<String> = ["(", ")", "[", "]", "\\{", "\\}"]

/// Take limits at their corners (∫) or directly above/below (∑, ∏).
let bigOperators: Set<String> = ["\\int", "\\oint", "\\sum", "\\prod"]

/// Shrunk below this = a script (measured scripts: 0.29–0.42; normal ≈ 1).
let scriptShrink = 0.6

/// Usual height relative to a digit; nil when size says nothing (+, ∫…).
func expectedHeight(_ label: String) -> Double? {
    if smallLetters.contains(label) { return 0.6 }
    if tallSymbols.contains(label) || descenders.contains(label) { return 1.0 }
    if brackets.contains(label) { return 1.1 }
    return nil
}

/// Actual height ratio to `base` ÷ expected ratio. ≈1 normal, < scriptShrink shrank.
func shrink(_ symbol: Symbol, as label: String, base: Symbol) -> Double? {
    guard let expected = expectedHeight(label),
          let baseExpected = expectedHeight(base.label),
          base.height > 0 else { return nil }
    let actualRatio = symbol.height / base.height
    let expectedRatio = expected / baseExpected
    return actualRatio / expectedRatio
}

/// The best guess plus any within `unsureMargin` of it.
func plausibleLabels(_ symbol: Symbol) -> [String] {
    guard let best = symbol.guesses.first else { return [symbol.label] }
    return symbol.guesses.filter { $0.score - best.score < unsureMargin }.map { $0.label }
}

/// openGroup: the previous symbol's role, so the "u m" of e_{sum} carry on after the "s".
func scriptRole(of symbol: Symbol, base: Symbol?, gap: Double, openGroup: ScriptRole) -> ScriptRole {
    guard let base, base.height > 0 else { return .normal }
    guard gap < base.height else { return .normal }
    let above = symbol.centerY < base.centerY

    // Big operators: by position. Limits sit in the top or bottom third.
    if bigOperators.contains(base.label) {
        guard symbol.height < 0.5 * base.height else { return .normal }
        let position = (symbol.centerY - base.top) / base.height   // 0 = top, 1 = bottom
        if position < 1.0 / 3 { return .sup }
        if position > 2.0 / 3 { return .sub }
        return .normal
    }

    let readings = plausibleLabels(symbol)
    let shrinks = readings.map { shrink(symbol, as: $0, base: base) }
    if !shrinks.contains(where: { $0 == nil }) && !readings.contains(where: { brackets.contains($0) }) {
        // Clearly raised and smaller: a superscript whatever it reads as
        if symbol.bottom < base.centerY && symbol.height < 0.75 * base.height { return .sup }

        guard shrinks.allSatisfy({ $0! < scriptShrink }) else { return .normal }
        return above ? .sup : .sub
    }

    // No expected size (+, -, =…): can't START a script, but can continue one (x^{n+1}).
    // Exception: a clearly raised "-" starts one (e^{-x}); "x - 1" sits at offset ≈ 0.
    let offset = (symbol.centerY - base.centerY) / base.height   // negative = higher
    let small = symbol.height < 0.7 * base.height
    if openGroup == .normal && symbol.label == "-" && offset < -0.35 { return .sup }

    if openGroup == .sup && small && offset < -0.2 { return .sup }
    if openGroup == .sub && small && offset > 0.2 { return .sub }
    return .normal
}

/// Moves limits written directly above/below a big operator to right after it (the n
/// under a ∑ often starts left of it).
func attachLimits(_ line: [Symbol]) -> [Symbol] {
    var taken = Set<Int>()
    var limits: [Int: [Symbol]] = [:]         // operator index -> its limits

    for (i, op) in line.enumerated() where bigOperators.contains(op.label) {
        let width = op.right - op.x
        let slack = max(0.5 * width, 0.25 * op.height)   // limits can be wider than the ∑
        for (j, candidate) in line.enumerated() where j != i && !taken.contains(j) {
            let centerX = (candidate.x + candidate.right) / 2
            guard centerX > op.x - slack, centerX < op.right + slack,
                  candidate.height < 0.7 * op.height else { continue }

            var limit = candidate
            if candidate.bottom <= op.top + 0.1 * op.height {
                limit.role = .sup
            } else if candidate.top >= op.bottom - 0.1 * op.height {
                limit.role = .sub
            } else {
                continue
            }
            taken.insert(j)
            limits[i, default: []].append(limit)
        }
    }

    var result: [Symbol] = []
    for (i, symbol) in line.enumerated() where !taken.contains(i) {
        result.append(symbol)
        result += limits[i] ?? []
    }
    return result
}

/// Marks each symbol as normal or a script. The base is the latest normal symbol that
/// isn't a floater.
func findScripts(_ line: [Symbol]) -> [Symbol] {
    var result = line.map { symbol in
        var fresh = symbol
        fresh.role = .normal
        return fresh
    }
    result = attachLimits(result)
    var base: Symbol? = nil
    var openGroup = ScriptRole.normal

    for i in result.indices {
        if result[i].role != .normal {        // a limit from attachLimits
            openGroup = result[i].role
            continue
        }
        let gap = i > 0 ? result[i].x - result[i - 1].right : 0
        let role = scriptRole(of: result[i], base: base, gap: gap, openGroup: openGroup)
        result[i].role = role
        if role == .normal {
            base = floaters.contains(result[i].label) ? nil : result[i]
        }
        openGroup = role
    }
    return result
}

// MARK: - Writing LaTeX

/// Each base followed by its scripts: x^{2}, e_{s u m}, \int_{0}^{1}.
func latex(for line: [Symbol]) -> String {
    var pieces: [String] = []
    var i = 0
    while i < line.count {
        var piece = line[i].label
        i += 1

        var subs: [String] = []
        var sups: [String] = []
        while i < line.count && line[i].role != .normal {
            if line[i].role == .sub {
                subs.append(line[i].label)
            } else {
                sups.append(line[i].label)
            }
            i += 1
        }
        if !subs.isEmpty { piece += "_{" + subs.joined(separator: " ") + "}" }
        if !sups.isEmpty { piece += "^{" + sups.joined(separator: " ") + "}" }
        pieces.append(piece)
    }
    return pieces.joined(separator: " ")
}

//
//  Layout.swift
//  InkToLatex
//
// How symbols sit relative to each other: lines, baselines, sizes.
// Pure logic, like Recognizer.swift: data in, answers out.
//
// The recognizer only sees a symbol's SHAPE: normalize() scales and centers every
// drawing, so size and position are thrown away. This file brings them back, from
// the symbol's line, to break ties between look-alikes:
//   - g y p q hang below the line; 9 and most others don't
//   - small letters (a c e o s x …) are about half as tall as digits

import Foundation

struct LineMetrics {
    let baseline: Double        // where symbols' bottoms typically sit (y grows downward)
    let typicalHeight: Double   // a typical symbol's height (for "how far below the line")
    let tallHeight: Double?     // a typical TALL symbol's height, if the line has any
                                // (needed for "is this small?"; see measureLine)
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

/// Hang below the baseline
let descenders: Set<String> = ["g", "y", "p", "q", "j", "\\mu", "\\beta", "\\phi"]
/// Float above the baseline (their bottoms say nothing about where the line is)
let floaters: Set<String> = ["-", "=", "\\cdot", "\\approx", "\\sim", "+", "\\times", "\\div", "\\pm"]
/// About half as tall as a digit
let smallLetters: Set<String> = ["a", "c", "e", "m", "n", "o", "r", "s", "u", "v", "w", "x", "z",
                                 "\\alpha", "\\omega", "\\sigma", "\\pi"]
/// Tiny on purpose: a dot. Anything bigger is something else (often a small 0)
let tinySymbols: Set<String> = ["\\cdot", "."]
/// Full height: the reference for "how tall is tall" on a line
let tallSymbols: Set<String> = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
                                "b", "d", "f", "h", "k", "\\delta", "\\theta", "\\lambda"]

// MARK: - Measuring a line

/// What a "normal" symbol on a line looks like.


/// Is the recognizer sure about this symbol? (Its best guess is clearly ahead.)
func isConfident(_ symbol: Symbol) -> Bool {
    symbol.guesses.count < 2 || symbol.guesses[1].score - symbol.guesses[0].score >= unsureMargin
}

/// Measures a line from the symbols we can TRUST: ones the recognizer is confident about.
/// (Unsure symbols are the ones we're trying to fix, so their guesses can't be used to
/// measure the line: a "g" misread as "9" would count as sitting on the line and drag
/// the baseline down.)
///
/// The baseline is the median bottom of trusted symbols that SHOULD sit on the line:
/// no descenders (they'd drag it down; think of "yay") and no floaters like "-".
/// Returns nil if there are none: nothing to measure the line by.
///
/// For size, "typical height" alone can mislead: on a line like "x + y" the typical symbol
/// is a small letter, so x would look full-size. So size checks compare against the
/// median height of trusted TALL symbols (digits, b, d, h…), and only when there are some.
func measureLine(_ line: [Symbol]) -> LineMetrics? {
    let sitters = line.filter {
        isConfident($0) && !descenders.contains($0.label) && !floaters.contains($0.label)
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
    let relativeHeight: Double?   // height ÷ a tall symbol's height (nil: no tall reference)
    let drop: Double              // how far the bottom is below the baseline ÷ typical height
                                  // (≈0 on the line, ≈0.3+ hanging below, negative = above)
    let size: Double              // height ÷ typical height (a dot ≈ 0.1, a letter ≈ 1)
}

func measure(_ symbol: Symbol, on line: LineMetrics) -> SymbolMeasure {
    let symbolHeight = symbol.bottom - symbol.top
    let relativeHeight = line.tallHeight.map { symbolHeight / $0 }   // nil stays nil
    let drop = (symbol.bottom - line.baseline) / line.typicalHeight
    return SymbolMeasure(relativeHeight: relativeHeight, drop: drop,
                         size: symbolHeight / line.typicalHeight)
}

// MARK: - The rules

/// How much worse a guess gets when it doesn't fit (scores: lower = better).
let mismatchPenalty = 0.5

/// Adds up the penalties for guessing `label` for a symbol measured like this.
func penalty(for label: String, _ m: SymbolMeasure) -> Double {
    var total = 0.0

    // Descenders must hang below the line...
    if descenders.contains(label) && m.drop < 0.15 { total += mismatchPenalty }
    // ...and symbols that sit on the line must not (floaters are free to be anywhere).
    if !descenders.contains(label) && !floaters.contains(label) && m.drop > 0.3 {
        total += mismatchPenalty
    }

    // Dots are tiny; a "dot" a third the size of a letter is really a small 0 or o.
    // And a real symbol isn't that tiny (floaters like "-" are flat, so they're exempt).
    if tinySymbols.contains(label) && m.size > 0.35 { total += mismatchPenalty }
    if !tinySymbols.contains(label) && !floaters.contains(label) && m.size < 0.15 {
        total += mismatchPenalty
    }

    // Size, only when the line has a tall reference to compare against
    if let h = m.relativeHeight {
        if smallLetters.contains(label) && h > 0.85 { total += mismatchPenalty }   // too big for a small letter
        if tallSymbols.contains(label) && h < 0.65 { total += mismatchPenalty }    // too small for a digit/tall letter
    }
    return total
}

// MARK: - Re-ranking

/// Only step in when the recognizer is unsure: the top two guesses are this close.
let unsureMargin = 0.3

/// Re-ranks one symbol's guesses using where it sits on its line.
/// Spatial rules are a tie-breaker, not an override: a clear winner is left alone,
/// and only the top 3 guesses are reconsidered.
func rerank(_ guesses: [Match], _ m: SymbolMeasure) -> [Match] {
    guard guesses.count >= 2,
          guesses[1].score - guesses[0].score < unsureMargin else { return guesses }

    let top = guesses.prefix(3).map { Match(label: $0.label, score: $0.score + penalty(for: $0.label, m)) }
    return top.sorted { $0.score < $1.score } + guesses.dropFirst(3)
}

/// Applies the spatial rules to a whole line: first finds its superscripts and
/// subscripts, then re-ranks the NORMAL symbols' guesses by size and position.
/// Scripts are small and raised/lowered on purpose, so they'd break the size and
/// baseline rules: they're left out of measuring the line and aren't re-ranked.
///
/// Then it looks for scripts AGAIN: re-ranking can change a label (a tiny "·" that's
/// really a small subscript 0), and that changes what counts as a script.
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

/// "|" comes in pairs (|x|). A line with exactly one "|" almost certainly has a 1 that
/// was misread, so if "1" is among that symbol's top 3 guesses, it becomes a 1.
func fixLoneBar(_ line: [Symbol]) -> [Symbol] {
    let bars = line.indices.filter { line[$0].label == "|" }
    guard bars.count == 1, let i = bars.first,
          line[i].guesses.prefix(3).contains(where: { $0.label == "1" }) else { return line }
    var fixed = line
    fixed[i].label = "1"
    return fixed
}

// MARK: - Lines

/// Every line is at least as tall as a typical symbol on the page, so a line that
/// starts with a flat "-" still catches the digits written next to it. Measured from
/// the page, not a fixed number of points, so it works at any zoom: written zoomed in,
/// your letters are only ~10 points tall.
/// A small symbol may sit this far outside a line (× the line's height) and still join
/// it: a raised ² can sit completely above its x.
let scriptLineMargin = 0.5

/// One line while we build it: its vertical band and its symbols.
struct LineBand {
    var top: Double
    var bottom: Double
    var symbols: [Symbol]
    var height: Double { bottom - top }
}

/// Groups symbols into lines, top to bottom; each line reads left to right.
///
/// TALLEST symbols go first, so normal-size symbols set up each line's band before the
/// small ones arrive. A symbol joins a line if its center is inside the band; a SMALL
/// symbol (under 70% of the line's height) may also be up to half a line-height above or
/// below it. That's how a raised ² finds its x instead of starting a line of its own.
func groupIntoLines(_ symbols: [Symbol]) -> [[Symbol]] {
    let tallestFirst = symbols.sorted { $0.height > $1.height }
    let minLineHeight = median(symbols.map { $0.height })   // a typical symbol's height
    var bands: [LineBand] = []

    for symbol in tallestFirst {
        // How far the symbol's center is outside a band (0 = inside it)
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
            if inside {                       // only symbols inside the band widen it,
                bands[i].top = min(bands[i].top, symbol.top)          // so scripts can't
                bands[i].bottom = max(bands[i].bottom, symbol.bottom) // drag it into the
            }                                                          // next line
        } else {
            let half = max(symbol.height, minLineHeight) / 2          // a new line
            bands.append(LineBand(top: min(symbol.top, symbol.centerY - half),
                                  bottom: max(symbol.bottom, symbol.centerY + half),
                                  symbols: [symbol]))
        }
    }
    return bands.sorted { $0.top < $1.top }
                .map { band in band.symbols.sorted { $0.x < $1.x } }
}

// MARK: - Superscripts and subscripts
//
// A script is a symbol that is SMALLER THAN IT SHOULD BE next to the symbol before it
// (its base). "Should be" is the key: in "2x" the x is smaller than the 2, but small
// letters always are, so it's normal. In "e₀" the 0 is smaller than the e even though
// digits are normally taller: it shrank, so it's a script. Then up or down picks ^ or _.

enum ScriptRole {
    case normal, sup, sub   // sup = superscript (^), sub = subscript (_)
}

/// Brackets: about digit height, so (a+b)² has a base with a known size
let brackets: Set<String> = ["(", ")", "[", "]", "\\{", "\\}"]

/// Big operators: they take limits, either at their top and bottom corners (how ∫ is
/// usually written) or directly above and below (how ∑ and ∏ are).
let bigOperators: Set<String> = ["\\int", "\\oint", "\\sum", "\\prod"]

/// Shrunk below this = a script. Your scripts measured 0.29–0.42; normal symbols ≈ 1.
let scriptShrink = 0.6

/// A label's usual height compared with a digit: small letters 0.6, tall symbols and
/// descenders 1. nil for everything else (+, (, ∫…): their size says nothing.
func expectedHeight(_ label: String) -> Double? {
    if smallLetters.contains(label) { return 0.6 }
    if tallSymbols.contains(label) || descenders.contains(label) { return 1.0 }
    if brackets.contains(label) { return 1.1 }                 // a bit taller than a digit
    return nil
}

/// How much smaller `symbol`, read as `label`, is than it "should" be next to `base`.
/// About 1 = the expected size; under `scriptShrink` = it shrank. nil = can't tell.
func shrink(_ symbol: Symbol, as label: String, base: Symbol) -> Double? {
    guard let expected = expectedHeight(label),
          let baseExpected = expectedHeight(base.label),
          base.height > 0 else { return nil }
    let actualRatio = symbol.height / base.height
    let expectedRatio = expected / baseExpected
    return actualRatio / expectedRatio
}

/// The labels a symbol could plausibly be: its best guess, plus any guess within
/// `unsureMargin` of it.
func plausibleLabels(_ symbol: Symbol) -> [String] {
    guard let best = symbol.guesses.first else { return [symbol.label] }
    return symbol.guesses.filter { $0.score - best.score < unsureMargin }.map { $0.label }
}

/// Is `symbol` a superscript or subscript of `base`?
/// - gap: how far right of the previous symbol it starts
/// - openGroup: the role of the symbol just before it, so the "u" and "m" of e_{sum}
///   carry on after the "s"
func scriptRole(of symbol: Symbol, base: Symbol?, gap: Double, openGroup: ScriptRole) -> ScriptRole {
    guard let base, base.height > 0 else { return .normal }   // nothing to attach to
    guard gap < base.height else { return .normal }           // too far right to belong
    let above = symbol.centerY < base.centerY

    // ∫ and ∑: everything looks small next to them, so go by position. A limit is small
    // and sits in the top or bottom third; the x in "∫ x" sits in the middle.
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
        // Clearly RAISED (its bottom is above the base's middle) and smaller than the base:
        // a superscript whatever it is. Nothing sitting on the line floats up there, so a
        // tie like "z or 2?" in (a+b)² doesn't matter: it's an exponent either way.
        if symbol.bottom < base.centerY && symbol.height < 0.75 * base.height { return .sup }

        guard shrinks.allSatisfy({ $0! < scriptShrink }) else { return .normal }
        return above ? .sup : .sub
    }

    // No expected size (+, -, =…): it can't START a script, but it can carry
    // one on, like the + in x^{n+1}, if it's small and clearly on the script's side.
    let offset = (symbol.centerY - base.centerY) / base.height   // negative = higher
    let small = symbol.height < 0.7 * base.height
    // A minus clearly RAISED right after a base starts a superscript: e^{-x}. A minus in
    // "x - 1" sits around the middle of the x (offset ≈ 0); one in an exponent sits near
    // the top (≈ -0.5). Stricter than continuing a group (-0.2), since starting one from
    // a misplaced "-" would swallow everything after it.
    if openGroup == .normal && symbol.label == "-" && offset < -0.35 { return .sup }

    if openGroup == .sup && small && offset < -0.2 { return .sup }
    if openGroup == .sub && small && offset > 0.2 { return .sub }
    return .normal
}

/// Finds limits written DIRECTLY above or below a big operator (∑_{n = 1}^{\infty}) and
/// moves each one right after its operator, so the line reads "∑, its limits, the rest".
/// (Left to right alone would scatter them: the n under a ∑ often starts left of it.)
/// A limit is small, roughly centered over the operator, and entirely above or below it.
func attachLimits(_ line: [Symbol]) -> [Symbol] {
    var taken = Set<Int>()                    // indices already used as someone's limit
    var limits: [Int: [Symbol]] = [:]         // operator index -> its limits, left to right

    for (i, op) in line.enumerated() where bigOperators.contains(op.label) {
        let width = op.right - op.x
        let slack = max(0.5 * width, 0.25 * op.height)   // limits can be wider than the ∑
        for (j, candidate) in line.enumerated() where j != i && !taken.contains(j) {
            let centerX = (candidate.x + candidate.right) / 2
            guard centerX > op.x - slack, centerX < op.right + slack,
                  candidate.height < 0.7 * op.height else { continue }

            var limit = candidate
            if candidate.bottom <= op.top + 0.1 * op.height {
                limit.role = .sup                             // above it: the upper limit
            } else if candidate.top >= op.bottom - 0.1 * op.height {
                limit.role = .sub                             // below it: the lower limit
            } else {
                continue                                      // beside it: not a limit
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

/// Marks each symbol on a line (already left to right) as normal or a script.
/// The base is the latest normal symbol; a floater like "+" or "=" is never a base.
/// Limits above/below a big operator are found first (attachLimits) and kept as they are.
func findScripts(_ line: [Symbol]) -> [Symbol] {
    var result = line.map { symbol in
        var fresh = symbol
        fresh.role = .normal                  // start clean; roles are worked out here
        return fresh
    }
    result = attachLimits(result)
    var base: Symbol? = nil
    var openGroup = ScriptRole.normal

    for i in result.indices {
        if result[i].role != .normal {        // a limit attachLimits already placed
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

/// One line as LaTeX: each base followed by its scripts: x^{2}, e_{s u m}, \int_{0}^{1}.
func latex(for line: [Symbol]) -> String {
    var pieces: [String] = []
    var i = 0
    while i < line.count {
        var piece = line[i].label          // a base (a normal symbol)
        i += 1

        // collect the scripts right after it
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

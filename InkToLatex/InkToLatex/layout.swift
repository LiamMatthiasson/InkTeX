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
/// Full height: the reference for "how tall is tall" on a line
let tallSymbols: Set<String> = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
                                "b", "d", "f", "h", "k", "\\delta", "\\theta", "\\lambda"]

// MARK: - Measuring a line

/// What a "normal" symbol on a line looks like.
struct LineMetrics {
    let baseline: Double        // where symbols' bottoms typically sit (y grows downward)
    let typicalHeight: Double   // a typical symbol's height (for "how far below the line")
    let tallHeight: Double?     // a typical TALL symbol's height, if the line has any
                                // (needed for "is this small?"; see measureLine)
}

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
}

func measure(_ symbol: Symbol, on line: LineMetrics) -> SymbolMeasure {
    let symbolHeight = symbol.bottom - symbol.top
    let relativeHeight = line.tallHeight.map { symbolHeight / $0 }   // nil stays nil
    let drop = (symbol.bottom - line.baseline) / line.typicalHeight
    return SymbolMeasure(relativeHeight: relativeHeight, drop: drop)
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

/// Applies the spatial rules to a whole line: each symbol's label becomes its best
/// guess after re-ranking. Lines too short to measure are returned unchanged.
func applySpatialContext(_ line: [Symbol]) -> [Symbol] {
    guard let metrics = measureLine(line) else { return line }

    return line.map { symbol in
        var adjusted = symbol
        let reranked = rerank(symbol.guesses, measure(symbol, on: metrics))
        if let best = reranked.first { adjusted.label = best.label }
        return adjusted
    }
}

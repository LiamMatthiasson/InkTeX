// Text and math together. Each line's ink is also read by Apple's Vision (on device),
// which says WHERE each word is. Symbols under a confidently read word become text;
// the rest become inline math: "the area is x²" → the area is $x^{2}$.

import Foundation
import CoreGraphics
import Vision

enum LineKind {
    case math, text
}

enum DocPart: Equatable {
    case text(String)
    case math(String)   // $…$
}

enum DocBlock: Equatable {
    case paragraph([DocPart])
    case display(String)        // \[ … \]
}

/// One word Vision read; left/right in page coordinates.
nonisolated struct ReadWord: Sendable {
    let text: String
    let left: Double
    let right: Double
    let confidence: Float
}

nonisolated struct TextReading: Sendable {
    let text: String
    let confidence: Float     // 0…1
    var words: [ReadWord] = []
}

// MARK: - Reading handwriting with Vision (runs in the background)

nonisolated func readHandwriting(_ strokes: [[Point]], letterHeight: Double) -> TextReading {
    let nothing = TextReading(text: "", confidence: 0)
    guard let ink = renderInk(strokes, letterHeight: letterHeight) else { return nothing }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate        // handles handwriting
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["en-US"]
    do {
        try VNImageRequestHandler(cgImage: ink.image, options: [:]).perform([request])
    } catch {
        return nothing
    }

    let observations = (request.results ?? []).sorted { $0.boundingBox.minX < $1.boundingBox.minX }
    var words: [ReadWord] = []
    var texts: [String] = []
    var confidences: [Float] = []

    for observation in observations {
        guard let candidate = observation.topCandidates(1).first else { continue }
        texts.append(candidate.string)
        confidences.append(candidate.confidence)

        // Split on spaces ("x+1" stays whole, so its "+" marks it as math) and map each
        // piece's box back to page coordinates.
        let s = candidate.string
        var i = s.startIndex
        while i < s.endIndex {
            while i < s.endIndex, s[i] == " " { i = s.index(after: i) }
            let start = i
            while i < s.endIndex, s[i] != " " { i = s.index(after: i) }
            guard start < i, let box = try? candidate.boundingBox(for: start..<i) else { continue }
            words.append(ReadWord(text: String(s[start..<i]),
                                  left: ink.pageX(box.boundingBox.minX),
                                  right: ink.pageX(box.boundingBox.maxX),
                                  confidence: candidate.confidence))
        }
    }
    guard !texts.isEmpty else { return nothing }
    let confidence = confidences.reduce(0, +) / Float(confidences.count)
    return TextReading(text: texts.joined(separator: " "), confidence: confidence, words: words)
}

nonisolated struct RenderedInk {
    let image: CGImage
    let minX: Double, scale: Double, pad: Double, width: Double

    /// Vision's 0…1 across the image → page x
    func pageX(_ fraction: Double) -> Double {
        (fraction * width - pad) / scale + minX
    }
}

/// Black ink on white, letters scaled to ~40 px tall (where Vision reads best).
nonisolated func renderInk(_ strokes: [[Point]], letterHeight: Double) -> RenderedInk? {
    let points = strokes.flatMap { $0 }
    guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
          let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }

    var scale = min(max(40 / max(letterHeight, 1), 0.5), 8)
    scale = min(scale, 4000 / max(maxX - minX, 1))
    let pad = 24.0
    let width = Int((maxX - minX) * scale + 2 * pad)
    let height = Int((maxY - minY) * scale + 2 * pad)

    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // Page y grows downward, image y upward
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)

    context.setStrokeColor(gray: 0, alpha: 1)
    context.setLineWidth(4)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    for stroke in strokes {
        guard let first = stroke.first else { continue }
        func spot(_ p: Point) -> CGPoint {
            CGPoint(x: (p.x - minX) * scale + pad, y: (p.y - minY) * scale + pad)
        }
        context.move(to: spot(first))
        if stroke.count == 1 {
            context.addLine(to: spot(first).applying(.init(translationX: 0.5, y: 0)))   // a dot
        }
        for p in stroke.dropFirst() {
            context.addLine(to: spot(p))
        }
    }
    context.strokePath()
    guard let image = context.makeImage() else { return nil }
    return RenderedInk(image: image, minX: minX, scale: scale, pad: pad, width: Double(width))
}

// MARK: - Words or math?

/// Short words that count as text (single letters never do: likely variables).
let commonShortWords: Set<String> = ["is", "of", "to", "in", "on", "at", "by", "be", "as", "an",
                                     "or", "if", "it", "we", "so", "no", "do", "up", "my", "me",
                                     "he", "us", "am", "go"]

/// Confident, all letters, and 3+ long or a common short word ("x+1", "2" aren't).
func looksLikeWord(_ word: ReadWord) -> Bool {
    guard word.confidence >= 0.4 else { return false }
    let core = word.text.trimmingCharacters(in: .punctuationCharacters)
    guard !core.isEmpty, core.allSatisfy({ $0.isLetter }) else { return false }
    return core.count >= 3 || commonShortWords.contains(core.lowercased())
}

/// Splits a line into words and inline-math runs; nil (a display equation) if no words.
/// Scripts go with their base; fractions are always math.
func mixParts(_ line: [Symbol], _ reading: TextReading) -> [DocPart]? {
    let words = reading.words.filter { looksLikeWord($0) }
    guard !words.isEmpty, !line.isEmpty else { return nil }
    let margin = 0.3 * median(line.map { $0.height })

    func word(under s: Symbol) -> Int? {
        guard s.children.isEmpty else { return nil }
        let centerX = (s.x + s.right) / 2
        return words.firstIndex { centerX >= $0.left - margin && centerX <= $0.right + margin }
    }

    var parts: [DocPart] = []
    var mathRun: [Symbol] = []
    var lastWord: Int? = nil
    var baseWord: Int? = nil

    func flushMath() {
        if !mathRun.isEmpty { parts.append(.math(latex(for: mathRun))) }
        mathRun = []
    }

    for s in line {
        let w = s.role == .normal ? word(under: s) : baseWord
        if s.role == .normal { baseWord = w }
        if let w {
            flushMath()
            if w != lastWord { parts.append(.text(words[w].text)) }
            lastWord = w
        } else {
            mathRun.append(s)
            lastWord = nil
        }
    }
    flushMath()

    let hasText = parts.contains { if case .text = $0 { true } else { false } }
    return hasText ? parts : nil
}

/// Escapes LaTeX's special characters ("50% off" would otherwise start a comment).
func escapeForLaTeX(_ text: String) -> String {
    var out = ""
    for ch in text {
        switch ch {
        case "\\": out += "\\textbackslash{}"
        case "&", "%", "$", "#", "_", "{", "}": out += "\\" + String(ch)
        case "~": out += "\\textasciitilde{}"
        case "^": out += "\\textasciicircum{}"
        default: out.append(ch)
        }
    }
    return out
}

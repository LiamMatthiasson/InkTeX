// Text and math together. Every line of ink is ALSO shown to Apple's Vision framework,
// which reads handwritten words on the device (free, offline, no LLM) and says WHERE
// each word is. Then, word by word:
//
//   a word Vision read confidently  → text        ("the", "area", "is")
//   everything else                 → math        (x², ∫, fractions…), from our recognizer
//
// so "the area is x²" becomes   the area is $x^{2}$   instead of all-text or all-math.
// A line with no words at all is a display equation. Lines of text join into paragraphs.
//
//   NoteModel.readTextLines()  renders each line's ink and asks Vision (background)
//   mixParts(…)                splits a line into text and math parts using word positions
//   escapeForLaTeX(…)          makes text safe to put in a .tex file

import Foundation
import CoreGraphics
import Vision

/// Is a line math or text? (Text = it has at least one word in it.)
enum LineKind {
    case math, text
}

/// A piece of a paragraph.
enum DocPart: Equatable {
    case text(String)   // words, as written
    case math(String)   // inline math: $…$
}

/// A block of the finished document.
enum DocBlock: Equatable {
    case paragraph([DocPart])   // text with inline math, possibly several lines joined
    case display(String)        // an equation on its own line: \[ … \]
}

/// One word Vision read, and where it is on the page (left/right in page coordinates).
nonisolated struct ReadWord: Sendable {
    let text: String
    let left: Double
    let right: Double
    let confidence: Float
}

/// What Vision read on a line.
nonisolated struct TextReading: Sendable {
    let text: String          // the whole line
    let confidence: Float     // 0…1
    var words: [ReadWord] = []
}

// MARK: - Reading handwriting with Vision (runs in the background)

/// Draws the strokes as black ink on white and asks Vision to read them, word by word.
nonisolated func readHandwriting(_ strokes: [[Point]], letterHeight: Double) -> TextReading {
    let nothing = TextReading(text: "", confidence: 0)
    guard let ink = renderInk(strokes, letterHeight: letterHeight) else { return nothing }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate        // the slower, better reader (handles handwriting)
    request.usesLanguageCorrection = true       // "helo" → "hello"
    request.recognitionLanguages = ["en-US"]
    do {
        try VNImageRequestHandler(cgImage: ink.image, options: [:]).perform([request])
    } catch {
        return nothing
    }

    // Each observation is a run of text; read them left to right
    let observations = (request.results ?? []).sorted { $0.boundingBox.minX < $1.boundingBox.minX }
    var words: [ReadWord] = []
    var texts: [String] = []
    var confidences: [Float] = []

    for observation in observations {
        guard let candidate = observation.topCandidates(1).first else { continue }
        texts.append(candidate.string)
        confidences.append(candidate.confidence)

        // Split on spaces (keeping "x+1" whole, so its "+" shows it's math) and ask
        // Vision where each piece is. Its boxes are 0…1 across the image; convert back
        // to page coordinates.
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

/// An image of some ink, plus how to map the image back onto the page.
nonisolated struct RenderedInk {
    let image: CGImage
    let minX: Double, scale: Double, pad: Double, width: Double

    /// A position across the image (0…1, as Vision reports it) → page x
    func pageX(_ fraction: Double) -> Double {
        (fraction * width - pad) / scale + minX
    }
}

/// The strokes as an image: letters scaled to about 40 pixels tall (Vision reads best
/// around there, and you write ~10 points tall when zoomed in), with a white margin.
nonisolated func renderInk(_ strokes: [[Point]], letterHeight: Double) -> RenderedInk? {
    let points = strokes.flatMap { $0 }
    guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
          let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }

    var scale = min(max(40 / max(letterHeight, 1), 0.5), 8)
    scale = min(scale, 4000 / max(maxX - minX, 1))       // keep very long lines a sane size
    let pad = 24.0
    let width = Int((maxX - minX) * scale + 2 * pad)
    let height = Int((maxY - minY) * scale + 2 * pad)

    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    context.setFillColor(gray: 1, alpha: 1)                          // white paper
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // Page y grows downward; image y grows upward. Flip so the words aren't upside down.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)

    context.setStrokeColor(gray: 0, alpha: 1)                        // black ink
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

/// Short words that count as text. Single letters never do: "a" or "x" alone is far
/// more likely a variable.
let commonShortWords: Set<String> = ["is", "of", "to", "in", "on", "at", "by", "be", "as", "an",
                                     "or", "if", "it", "we", "so", "no", "do", "up", "my", "me",
                                     "he", "us", "am", "go"]

/// A real word: Vision is fairly sure, it's all letters (trailing punctuation allowed),
/// and it's 3+ letters or a common short word. "x+1", "f(x)" and "2" are not words.
func looksLikeWord(_ word: ReadWord) -> Bool {
    guard word.confidence >= 0.4 else { return false }
    let core = word.text.trimmingCharacters(in: .punctuationCharacters)
    guard !core.isEmpty, core.allSatisfy({ $0.isLetter }) else { return false }
    return core.count >= 3 || commonShortWords.contains(core.lowercased())
}

/// Splits a line into text and math. Each symbol under a word Vision read becomes part
/// of that word; runs of the other symbols become inline math. Scripts go with their base;
/// fractions are always math. Returns nil when there are no words: a display equation.
func mixParts(_ line: [Symbol], _ reading: TextReading) -> [DocPart]? {
    let words = reading.words.filter { looksLikeWord($0) }
    guard !words.isEmpty, !line.isEmpty else { return nil }
    let margin = 0.3 * median(line.map { $0.height })

    /// Which word (if any) is this symbol under?
    func word(under s: Symbol) -> Int? {
        guard s.children.isEmpty else { return nil }              // a fraction: math
        let centerX = (s.x + s.right) / 2
        return words.firstIndex { centerX >= $0.left - margin && centerX <= $0.right + margin }
    }

    var parts: [DocPart] = []
    var mathRun: [Symbol] = []
    var lastWord: Int? = nil
    var baseWord: Int? = nil          // the word the current base symbol belongs to

    func flushMath() {
        if !mathRun.isEmpty { parts.append(.math(latex(for: mathRun))) }
        mathRun = []
    }

    for s in line {
        // a script follows its base: an x² is math whole, even if Vision saw the x as a word
        let w = s.role == .normal ? word(under: s) : baseWord
        if s.role == .normal { baseWord = w }
        if let w {
            flushMath()
            if w != lastWord { parts.append(.text(words[w].text)) }   // each word once
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

/// Text goes into the .tex file as is, except LaTeX's special characters, which need
/// escaping ("50% off" would otherwise start a comment at the %).
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

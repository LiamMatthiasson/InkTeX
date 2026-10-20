// Quick checks that the Swift recognizer gives the same answers as recognizer.js.
// The expected numbers below were produced by running the JavaScript version.
// Results print in Xcode's console (View > Debug Area > Activate Console).

import Foundation

/// A straight line from (x1, y1) to (x2, y2), as n + 1 evenly spaced points.
private func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ n: Int = 10) -> [Point] {
    (0...n).map { i in
        let t = Double(i) / Double(n)
        return Point(x: x1 + (x2 - x1) * t, y: y1 + (y2 - y1) * t)
    }
}

private func isClose(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.0001 }

private func check(_ name: String, _ passed: Bool) {
    print(passed ? "✅ \(name)" : "❌ \(name)")
}

func runRecognizerChecks() {
    print("---- Recognizer checks ----")

    // pathLength: the 3-4-5 triangle, and the empty list that used to crash
    check("pathLength 3-4-5 = 5", isClose(pathLength([Point(x: 1, y: 2), Point(x: 4, y: 6)]), 5))
    check("pathLength of nothing = 0", pathLength([]) == 0)

    // translateToOrigin: the line you worked out by hand
    let slid = translateToOrigin([Point(x: 50, y: 80), Point(x: 60, y: 80), Point(x: 70, y: 80)])
    check("translateToOrigin", isClose(slid[0].x, -10) && isClose(slid[1].x, 0) && isClose(slid[2].x, 10)
                               && slid.allSatisfy { isClose($0.y, 0) })

    // scaleToUnit: width 80 becomes width 1
    let zoomed = scaleToUnit([Point(x: -40, y: 0), Point(x: 0, y: 0), Point(x: 40, y: 0)])
    check("scaleToUnit", isClose(zoomed[0].x, -0.5) && isClose(zoomed[2].x, 0.5))

    // resample: the A-B-C example, 5 beads at distances 0, 5, 10, 15, 20
    let abc = resample([Point(x: 0, y: 0), Point(x: 10, y: 0), Point(x: 10, y: 10)], 5)
    let expectedABC: [(Double, Double)] = [(0, 0), (5, 0), (10, 0), (10, 5), (10, 10)]
    check("resample A-B-C", abc.count == 5 && zip(abc, expectedABC).allSatisfy { isClose($0.x, $1.0) && isClose($0.y, $1.1) })

    // resample across two strokes: no beads in the gap where the pen was lifted
    let twoStrokes = resample(flatten([[Point(x: 0, y: 0), Point(x: 10, y: 0)],
                                       [Point(x: 0, y: 10), Point(x: 10, y: 10)]]), 4)
    let expectedGap: [(Double, Double)] = [(0, 0), (6.6667, 0), (3.3333, 10), (10, 10)]
    check("resample skips the pen-up gap", zip(twoStrokes, expectedGap).allSatisfy { isClose($0.x, $1.0) && isClose($0.y, $1.1) })

    // recognize: a "+" written in the opposite stroke order and direction from its template
    let templates = [
        Template(label: "+", strokes: [line(170, 340, 230, 340), line(200, 310, 200, 370)]),
        Template(label: "-", strokes: [line(170, 340, 230, 340)]),
        Template(label: "1", strokes: [line(200, 300, 200, 380)]),
    ].map { PreparedTemplate($0) }

    let drawnPlus = [line(400, 170, 400, 110), line(430, 140, 370, 140)]
    let results = recognize(drawnPlus, templates: templates)
    for match in results {
        print("   \(match.label): \(String(format: "%.6f", match.score))")
    }
    // JavaScript gave: + 0.000000, 1 1.645027, - 2.045708
    check("recognize finds +", results.first?.label == "+")
    check("scores match JavaScript",
          results.count == 3
          && isClose(results[0].score, 0)
          && results[1].label == "1" && isClose(results[1].score, 1.645027)
          && results[2].label == "-" && isClose(results[2].score, 2.045708))


    // Layout: median, and re-ranking by size/position (see Layout.swift)
    check("median of 5", median([150, 172, 151, 138, 149]) == 150)
    check("median of 4", median([150, 151, 138, 149]) == 149.5)

    func sym(_ x: Double, _ top: Double, _ bottom: Double, _ guesses: [(String, Double)]) -> Symbol {
        let ranked = guesses.map { Match(label: $0.0, score: $0.1) }
        return Symbol(strokes: [], label: ranked[0].label, x: x, top: top, bottom: bottom, guesses: ranked)
    }
    // "2 g 9": the recognizer misread the g as 9 and the 9 as g; the confident 2 is the ruler
    let fixed = applySpatialContext([
        sym(0, 100, 150, [("2", 0.2), ("z", 0.9)]),
        sym(60, 118, 172, [("9", 1.20), ("g", 1.25)]),
        sym(120, 99, 151, [("g", 1.1), ("9", 1.2)]),
    ]).map { $0.label }
    check("re-rank 2 g 9", fixed == ["2", "g", "9"])
    // "3 s 5": a small s misread as 5, a tall 5 misread as s
    let sized = applySpatialContext([
        sym(0, 100, 150, [("3", 0.3), ("g", 1.2)]),
        sym(60, 125, 150, [("5", 1.0), ("s", 1.1)]),
        sym(120, 100, 151, [("s", 0.9), ("5", 0.95)]),
    ]).map { $0.label }
    check("re-rank 3 s 5", sized == ["3", "s", "5"])

    // Scripts, measured from your handwriting sample (screenshot pixels)
    func box(_ label: String, _ left: Double, _ right: Double, _ top: Double, _ bottom: Double) -> Symbol {
        Symbol(strokes: [], label: label, x: left, right: right, top: top, bottom: bottom,
               guesses: [Match(label: label, score: 0.2)])
    }
    let x2 = [box("x", 135, 265, 300, 440), box("2", 285, 385, 195, 285)]
    let e0 = [box("e", 615, 725, 280, 465), box("0", 765, 840, 385, 470)]
    let integral = [box("\\int", 990, 1160, 185, 560), box("x", 1170, 1265, 330, 460),
                    box("+", 1285, 1380, 325, 435), box("1", 1405, 1435, 320, 440)]
    let esum = [box("e", 150, 280, 705, 870), box("s", 305, 385, 825, 895),
                box("u", 390, 470, 820, 885), box("m", 500, 635, 815, 890)]
    let twoX = [box("2", 0, 50, 100, 150), box("x", 60, 95, 120, 150)]

    check("x^{2}", latex(for: applySpatialContext(x2)) == "x^{2}")
    check("e_{0}", latex(for: applySpatialContext(e0)) == "e_{0}")
    check("e_{s u m}", latex(for: applySpatialContext(esum)) == "e_{s u m}")
    check("\\int x + 1 (x is not a limit)", latex(for: applySpatialContext(integral)) == "\\int x + 1")
    check("2 x is not 2_{x}", latex(for: applySpatialContext(twoX)) == "2 x")

    // The ² must join its x's line, not start a line of its own
    let page = groupIntoLines(x2 + e0 + integral + esum)
    check("2 lines on the sample page", page.count == 2)
    check("first line reads x 2 e 0 ∫ x + 1", page.first?.map { $0.label } == ["x", "2", "e", "0", "\\int", "x", "+", "1"])
    print("   " + page.map { latex(for: applySpatialContext($0)) }.joined(separator: "   |   "))

    // ∑ with limits directly below (n = 1) and above (∞), then an x beside it
    let sum = [box("\\sum", 100, 200, 100, 250), box("n", 90, 120, 260, 290),
               box("\\infty", 120, 180, 60, 90), box("=", 125, 145, 270, 280),
               box("1", 150, 165, 258, 292), box("x", 210, 260, 150, 210)]
    check("\\sum_{n = 1}^{\\infty} x", latex(for: applySpatialContext(groupIntoLines(sum)[0])) == "\\sum_{n = 1}^{\\infty} x")
    // ∫ with corner limits: 0 at the bottom right, 1 at the top right
    let intLimits = [box("\\int", 100, 160, 100, 300), box("1", 165, 180, 95, 140),
                     box("0", 160, 185, 265, 305), box("x", 200, 250, 180, 230)]
    check("\\int_{0}^{1} x", latex(for: applySpatialContext(groupIntoLines(intLimits)[0])) == "\\int_{0}^{1} x")

    // "=" must never start a script, even if a small letter is its runner-up guess
    let yEquals = [box("y", 0, 40, 100, 170),
                   Symbol(strokes: [], label: "=", x: 50, right: 80, top: 115, bottom: 130,
                          guesses: [Match(label: "=", score: 0.5), Match(label: "z", score: 0.6)]),
                   box("2", 90, 120, 95, 150)]
    check("y = 2 (= is not an exponent)", latex(for: applySpatialContext(yEquals)) == "y = 2")
    // (a+b)²: the ) is a base with a known size now
    let paren = [box("(", 0, 15, 90, 160), box("a", 20, 50, 120, 150), box("+", 55, 80, 122, 145),
                 box("b", 85, 110, 100, 150), box(")", 115, 130, 90, 160), box("2", 135, 160, 60, 95)]
    check("( a + b )^{2}", latex(for: applySpatialContext(paren)) == "( a + b )^{2}")
    // a lone | with 1 among its guesses is a 1
    let lone = [box("x", 0, 30, 120, 150), box("=", 40, 70, 128, 140),
                Symbol(strokes: [], label: "|", x: 80, right: 85, top: 100, bottom: 150,
                       guesses: [Match(label: "|", score: 0.5), Match(label: "1", score: 0.7)])]
    check("x = 1 (lone | becomes 1)", latex(for: applySpatialContext(lone)) == "x = 1")

    // (a+b)² where the 2 is a near-tie with z: raised, so it's an exponent anyway
    var parenZ = paren
    parenZ[5] = Symbol(strokes: [], label: "z", x: 135, right: 160, top: 60, bottom: 95,
                       guesses: [Match(label: "z", score: 1.05), Match(label: "2", score: 1.12)])
    check("( a + b )^{z} (raised, even when read as z)", latex(for: applySpatialContext(parenZ)) == "( a + b )^{z}")

    // a small "(" after f is f(x), not f_{(}  (your numbers from the iPad)
    let fOfX = [box("f", 58, 66, 53, 67), box("(", 71, 73, 58, 67), box("x", 79, 85, 59, 67), box(")", 89, 92, 56, 67)]
    check("f ( x )", latex(for: applySpatialContext(fOfX)) == "f ( x )")

    // negative exponents: a raised minus starts the superscript; a middle one doesn't
    let eMinusX = [box("e", 0, 40, 100, 160), box("-", 45, 60, 104, 106), box("x", 62, 80, 85, 110)]
    check("e^{- x}", latex(for: applySpatialContext(eMinusX)) == "e^{- x}")
    let eSubtractX = [box("e", 0, 40, 100, 160), box("-", 45, 60, 129, 131), box("x", 65, 90, 135, 160)]
    check("e - x (a middle minus is subtraction)", latex(for: applySpatialContext(eSubtractX)) == "e - x")

    // Fractions: x = (a + b) over 2
    let fractionPage = [box("x", 40, 60, 115, 135), box("=", 70, 90, 122, 128),
                        box("a", 105, 120, 100, 120), box("+", 122, 135, 103, 117), box("b", 138, 155, 92, 120),
                        box("-", 100, 160, 129, 131),
                        box("2", 120, 140, 140, 170)]
    let fractionLines = groupIntoLines(combineFractions(fractionPage))
    check("fraction: one line", fractionLines.count == 1)
    check("x = \\frac{a + b}{2}", fractionLines.first.map { latex(for: applySpatialContext($0)) } == "x = \\frac{a + b}{2}")
    // ...but a minus with nothing above and below stays a minus
    let minusPage = [box("a", 0, 20, 110, 130), box("-", 25, 40, 119, 121), box("b", 45, 60, 100, 130)]
    check("a - b is not a fraction", groupIntoLines(combineFractions(minusPage)).first.map { latex(for: applySpatialContext($0)) } == "a - b")

    // Words or math?
    func word(_ text: String, _ left: Double, _ right: Double, _ confidence: Float = 0.8) -> ReadWord {
        ReadWord(text: text, left: left, right: right, confidence: confidence)
    }
    check("'the' is a word", looksLikeWord(word("the", 0, 10)))
    check("'is' is a word", looksLikeWord(word("is", 0, 10)))
    check("'x' alone is math", !looksLikeWord(word("x", 0, 10)))
    check("'x+1' is math", !looksLikeWord(word("x+1", 0, 10)))
    check("'f(x)' is math", !looksLikeWord(word("f(x)", 0, 10)))
    check("an unsure word is math", !looksLikeWord(word("hello", 0, 10, 0.2)))
    // "x is 2": the word in the middle is text, the x and the 2 are inline math
    let mixed = [box("x", 0, 10, 100, 110), box("i", 20, 22, 98, 110), box("s", 24, 30, 102, 110),
                 box("2", 40, 48, 97, 110)]
    let reading = TextReading(text: "x is 2", confidence: 0.8,
                              words: [word("x", 0, 10), word("is", 20, 30), word("2", 40, 48)])
    check("x is 2 → $x$ is $2$", mixParts(mixed, reading) == [.math("x"), .text("is"), .math("2")])
    check("escape 50% & $5", escapeForLaTeX("50% & $5") == "50\\% \\& \\$5")

    // The label guard: a template is the symbol itself, never ^ or _
    check("cleanLabel ^2 → 2", cleanLabel("^2") == "2")
    check("cleanLabel _{0} → 0", cleanLabel("_{0}") == "0")
    check("cleanLabel ' ^{10} ' → 10", cleanLabel(" ^{10} ") == "10")
    check("cleanLabel leaves \\alpha alone", cleanLabel("\\alpha") == "\\alpha")

    print("---------------------------")
}

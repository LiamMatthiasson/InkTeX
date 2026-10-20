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

    print("---------------------------")
}

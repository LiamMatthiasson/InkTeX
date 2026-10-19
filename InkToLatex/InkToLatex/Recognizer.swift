// The $P point-cloud recognizer, ported line by line from recognizer.js.
// Like the JavaScript version, this file is pure logic: no screen, no PencilKit,
// no saving. Points go in, ranked guesses come out.

import Foundation

// MARK: - Data types

/// One point on the page.
/// `stroke` says which stroke the point came from (set by `flatten`). It is left out
/// of saving/loading (CodingKeys below), so saved templates stay just { x, y } and
/// can be shared with the web version.
struct Point: Codable {
    var x: Double
    var y: Double
    var stroke: Int = 0

    enum CodingKeys: String, CodingKey {
        case x, y
    }
}

/// A saved example of a symbol. The label is the LaTeX itself ("2", "+", "\\alpha").
/// Stores RAW strokes, never the normalized shape (same rule as the web version).
struct Template: Codable {
    var label: String
    var strokes: [[Point]]
}

/// A template with its normalized shape computed once, ahead of time.
struct PreparedTemplate {
    let label: String
    let shape: [Point]

    init(_ template: Template) {
        label = template.label
        shape = normalize(flatten(template.strokes))
    }
}

/// One guess: a label and how far the drawing is from it (lower = closer).
struct Match {
    let label: String
    let score: Double
}

let numPoints = 32

// MARK: - Preparing a drawing

/// Joins a symbol's strokes into one list, tagging each point with its stroke number.
func flatten(_ strokes: [[Point]]) -> [Point] {
    var points: [Point] = []
    for (index, stroke) in strokes.enumerated() {
        for p in stroke {
            points.append(Point(x: p.x, y: p.y, stroke: index))
        }
    }
    return points
}

/// Total length of the ink, skipping the jumps where the pen was lifted.
func pathLength(_ points: [Point]) -> Double {
    guard points.count > 1 else { return 0 }   // 0 or 1 points: no line to measure

    var total = 0.0
    for i in 1..<points.count {
        if points[i].stroke != points[i - 1].stroke { continue }   // pen was lifted here
        let dx = points[i].x - points[i - 1].x
        let dy = points[i].y - points[i - 1].y
        total += hypot(dx, dy)
    }
    return total
}

/// Places n evenly spaced "beads" along the ink.
func resample(_ points: [Point], _ n: Int) -> [Point] {
    guard let first = points.first else { return [] }

    let length = pathLength(points)

    // A single tap (a dot) has length 0: return n copies of that spot.
    if length == 0 {
        return Array(repeating: Point(x: first.x, y: first.y), count: n)
    }

    let beadDistance = length / Double(n - 1)
    var beads = [Point(x: first.x, y: first.y)]   // first bead = start point
    var walked = 0.0                              // distance from the start of the ink
    var nextBead = beadDistance                   // where the next bead goes

    // length > 0 means there are at least 2 points, so this range is safe
    for i in 1..<points.count {
        let a = points[i - 1]
        let b = points[i]
        if a.stroke != b.stroke { continue }      // pen lifted between a and b: no beads in the gap
        let segLength = hypot(b.x - a.x, b.y - a.y)
        if segLength == 0 { continue }            // pen didn't move

        while nextBead <= walked + segLength && beads.count < n {
            let t = (nextBead - walked) / segLength
            beads.append(Point(x: a.x + t * (b.x - a.x),
                               y: a.y + t * (b.y - a.y)))
            nextBead += beadDistance
        }
        walked += segLength
    }

    // Rounding errors can leave us one bead short; finish with the last point.
    let last = points[points.count - 1]
    while beads.count < n {
        beads.append(Point(x: last.x, y: last.y))
    }
    return beads
}

/// Slides the drawing so its center sits at (0, 0).
func translateToOrigin(_ points: [Point]) -> [Point] {
    guard !points.isEmpty else { return [] }

    var totalX = 0.0
    var totalY = 0.0
    for p in points {
        totalX += p.x
        totalY += p.y
    }
    let centerX = totalX / Double(points.count)
    let centerY = totalY / Double(points.count)

    var translated: [Point] = []
    for p in points {
        translated.append(Point(x: p.x - centerX, y: p.y - centerY))
    }
    return translated
}

/// Zooms the drawing so its bigger side is 1 (same scale for x and y, so shapes don't stretch).
func scaleToUnit(_ points: [Point]) -> [Point] {
    var minX = Double.infinity, maxX = -Double.infinity
    var minY = Double.infinity, maxY = -Double.infinity
    for p in points {
        minX = min(minX, p.x); maxX = max(maxX, p.x)
        minY = min(minY, p.y); maxY = max(maxY, p.y)
    }

    let size = max(maxX - minX, maxY - minY)
    guard size > 0 else { return points }      // a single dot: nothing to scale

    let scale = 1 / size
    var scaled: [Point] = []
    for p in points {
        scaled.append(Point(x: p.x * scale, y: p.y * scale))
    }
    return scaled
}

/// All three steps: resample, then slide, then zoom.
func normalize(_ points: [Point]) -> [Point] {
    scaleToUnit(translateToOrigin(resample(points, numPoints)))
}

// MARK: - Point-cloud matching

/// Each dot in `a` claims the closest unclaimed dot in `b`. Early picks count more.
///
/// `limit` makes it fast: once the running total reaches the limit, this match can't
/// win anymore, so it stops early ("early abandoning"). Most templates are rejected
/// after a few dots instead of all 32.
func greedyMatch(_ a: [Point], _ b: [Point], start: Int, limit: Double = .infinity) -> Double {
    let n = a.count
    var claimed = [Bool](repeating: false, count: n)
    var total = 0.0

    for k in 0..<n {
        let i = (start + k) % n
        var closest = -1
        var closestDist = Double.infinity
        for j in 0..<n where !claimed[j] {       // each dot in b can only be used once
            let d = hypot(a[i].x - b[j].x, a[i].y - b[j].y)
            if d < closestDist {
                closestDist = d
                closest = j
            }
        }
        claimed[closest] = true
        let weight = 1 - Double(k) / Double(n)
        total += weight * closestDist
        if total >= limit { return total }       // already too far: give up on this one
    }
    return total
}

/// Tries several starting dots, in both directions, and keeps the best score.
/// Each attempt only has to beat the best so far, so later attempts give up early.
/// If nothing beats `limit`, the result is just "at least limit" (the caller ignores it).
func cloudDistance(_ a: [Point], _ b: [Point], limit: Double = .infinity) -> Double {
    let n = a.count
    guard n > 0, b.count == n else { return .infinity }

    let step = max(1, Int(Double(n).squareRoot()))   // about 5 starting points for 32 dots
    var best = limit
    for start in stride(from: 0, to: n, by: step) {
        best = min(best, greedyMatch(a, b, start: start, limit: best))
        best = min(best, greedyMatch(b, a, start: start, limit: best))
    }
    return best
}

// MARK: - Recognition

/// Compares a symbol (its strokes) with every template.
/// Returns one Match per label, best first.
func recognize(_ strokes: [[Point]], templates: [PreparedTemplate]) -> [Match] {
    guard !templates.isEmpty else { return [] }

    let drawn = normalize(flatten(strokes))
    var bestPerLabel: [String: Double] = [:]   // label -> its closest template's score

    for template in templates {
        // Only this label's best so far matters: a template that can't beat it is skipped
        // early. Each label still ends up with its exact best score (for the top-3 list).
        let score = cloudDistance(drawn, template.shape, limit: bestPerLabel[template.label] ?? .infinity)
        if let best = bestPerLabel[template.label], best <= score { continue }
        bestPerLabel[template.label] = score
    }

    var results: [Match] = []
    for (label, score) in bestPerLabel {
        results.append(Match(label: label, score: score))
    }
    results.sort { $0.score < $1.score }
    return results
}

// convert.swift
// Turns the HWRT handwriting dataset into InkToLatex templates.
// Runs once on the Mac, not in the app:
//
//   cd ~/Developer/LaTex/tools
//   swift convert.swift
//
// Step 1: read symbols.csv and find the ids of the symbols we want.
// Step 2: go through train-data.csv, keep `perSymbol` samples of each wanted symbol
//         (each from a different writer), and write them to the app as
//         StarterTemplates.json.

import Foundation

/// One row of symbols.csv: a symbol's id, its LaTeX, and how many examples exist.
struct SymbolInfo {
    let id: Int
    let latex: String
    let trainCount: Int   // how many examples in train-data.csv (a count, not an index)
    let testCount: Int    // how many examples in test-data.csv
}

/// The symbols to include (as LaTeX, the same labels the app uses).
/// Chosen for math notes. Left out on purpose: i j l o (too close to 1 and 0) and
/// \Sigma (looks just like \sum), and \times
/// (rarely handwritten, and it steals x). Not in the dataset at all, so they stay your own
/// templates: = ( ) t
let wanted: Set<String> = [
    // digits
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
    // operators and relations
    "+", "-", "\\div", "\\cdot", "\\pm", "<", ">", "\\leq", "\\geq", "\\neq", "\\approx",
    // brackets and bars
    "[", "]", "\\{", "\\}", "|", "/",
    // letters
    "a", "b", "c", "d", "e", "f", "g", "h", "k", "m", "n", "p", "q", "r", "s", "u", "v", "w", "x", "y", "z",
    // Greek
    "\\alpha", "\\beta", "\\gamma", "\\delta", "\\theta", "\\lambda", "\\mu", "\\pi", "\\sigma", "\\phi", "\\omega", "\\Delta",
    // calculus and arrows
    "\\int", "\\oint", "\\sum", "\\prod", "\\partial", "\\infty", "\\rightarrow", "\\Rightarrow",
    // roots and primes
    "\\sqrt{}", "\\prime",
    // capital letters that don't look like a lowercase letter or digit
    // (C O S U V W X Z, I J K P Y are left out: c 0 5 u v w x z, 1 j k p y)
    "A", "B", "D", "E", "F", "G", "H", "L", "M", "N", "Q", "R", "T",
    // more Greek
    "\\varepsilon", "\\tau", "\\psi", "\\xi", "\\Gamma", "\\Theta", "\\Pi", "\\Phi", "\\Omega",
    // sets and logic
    "\\in", "\\notin", "\\subset", "\\subseteq", "\\cup", "\\cap", "\\emptyset", "\\forall", "\\exists",
    "\\nabla", "\\equiv", "\\perp", "\\angle", "\\therefore", "\\mapsto", "\\Leftrightarrow",
    // number sets (the dataset's \\mathds is the same blackboard bold as \\mathbb)
    "\\mathds{R}", "\\mathds{N}", "\\mathds{Z}", "\\mathds{Q}", "\\mathds{C}",
]

/// Dataset names → the LaTeX the app should write.
let rename: [String: String] = [
    "\\sqrt{}": "\\sqrt",            // the app adds the {…} around what's under it
    "\\prime": "'",                    // f'(x) is written with an apostrophe
    "\\mathds{R}": "\\mathbb{R}", "\\mathds{N}": "\\mathbb{N}", "\\mathds{Z}": "\\mathbb{Z}",
    "\\mathds{Q}": "\\mathbb{Q}", "\\mathds{C}": "\\mathbb{C}",   // \\mathbb is in amssymb
]

/// How many examples of each symbol to keep. Measured on the dataset's test writers:
/// 5 per symbol read 64% correctly, 10 per symbol 70% (88% in the top 3).
let perSymbol = 10

// ---- Read symbols.csv into a dictionary: id -> SymbolInfo ----

let text = try String(contentsOfFile: "hwrt/symbols.csv", encoding: .utf8)
var bySymbolID: [Int: SymbolInfo] = [:]

for line in text.split(whereSeparator: \.isNewline).dropFirst() {   // dropFirst skips the header row
    let parts = line.split(separator: ";")
    guard parts.count >= 4 else { continue }               // not a full row: skip it

    // Numbers come out of split as text, so convert them. Int(...) gives nil if it
    // isn't a number, and guard let skips the row instead of crashing.
    guard let id = Int(parts[0]),
          let trainCount = Int(parts[2]),
          let testCount = Int(parts[3]) else { continue }

    // The LaTeX is wrapped in single quotes, like '3'. Strip them.
    let latex = String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "'"))

    bySymbolID[id] = SymbolInfo(id: id, latex: latex, trainCount: trainCount, testCount: testCount)
}

print("Read \(bySymbolID.count) symbols.")

// ---- Print the symbols in this batch, sorted by their LaTeX ----

let batch = bySymbolID.values
    .filter { wanted.contains($0.latex) }
    .sorted { $0.latex < $1.latex }

print("\(batch.count) of the \(wanted.count) wanted symbols found.")

let missing = wanted.subtracting(batch.map { $0.latex })
if !missing.isEmpty {
    print("Not found in the dataset: \(missing.sorted())")
}

/*  for each line of train-data.csv (streamed):
    split into id, user, data, rest      (maxSplits: 3)
    if id isn't one of our batch's ids → skip   (most lines)
    if we already have 10 of this symbol → skip
    if we already have this writer for this symbol → skip   (variety!)
    decode the JSON data into strokes, dropping "time"
    add { label, strokes } to our list
    write the list to StarterTemplates.json
*/

// ---- Step 2 ----

/// One point as it appears in the dataset. The JSON also has "time", which we don't
/// need: Decodable simply ignores fields the struct doesn't list.
struct RawPoint: Decodable {
    let x: Double
    let y: Double
}

/// The same shape the app saves templates in: { "label": "3", "strokes": [[{"x":..,"y":..}]] }
struct OutPoint: Encodable { let x: Double; let y: Double }
struct OutTemplate: Encodable { let label: String; let strokes: [[OutPoint]] }

// Which ids we want, and what label each one gets (from step 1's dictionary)
var labelForID: [Int: String] = [:]
for info in batch { labelForID[info.id] = rename[info.latex] ?? info.latex }

var templates: [OutTemplate] = []
var countPerLabel: [String: Int] = [:]          // how many we've kept of each symbol
var writersSeen: [String: Set<String>] = [:]    // which writers we've used for each symbol

// "for each line of train-data.csv (streamed)": .lines hands over one line at a time,
// so the 1.2 GB file is never all in memory. `await` = wait for the next line to arrive.
let trainURL = URL(fileURLWithPath: "hwrt/train-data.csv")
var isHeader = true

for try await line in trainURL.lines {
    if isHeader { isHeader = false; continue }

    // "split into id, user, data, rest (maxSplits: 3)": the browser info at the end
    // can contain ";", so stop after 3 cuts and leave it in one piece.
    let parts = line.split(separator: ";", maxSplits: 3)
    guard parts.count >= 3, let id = Int(parts[0]) else { continue }

    // "if id isn't one of our batch's ids → skip"
    guard let label = labelForID[id] else { continue }

    // "if we already have perSymbol of this symbol → skip"
    if countPerLabel[label, default: 0] >= perSymbol { continue }

    // "if we already have this writer for this symbol → skip (variety!)"
    let writer = String(parts[1])
    if writersSeen[label, default: []].contains(writer) { continue }

    // "decode the JSON data into strokes, dropping time"
    guard let raw = try? JSONDecoder().decode([[RawPoint]].self, from: Data(parts[2].utf8)) else { continue }
    let strokes = raw.map { stroke in stroke.map { OutPoint(x: $0.x, y: $0.y) } }

    // "add { label, strokes } to our list"
    templates.append(OutTemplate(label: label, strokes: strokes))
    countPerLabel[label, default: 0] += 1
    writersSeen[label, default: []].insert(writer)
}

// "write the list to StarterTemplates.json", straight into the app's code folder,
// where Xcode picks it up automatically and bundles it into the app.
let outURL = URL(fileURLWithPath: "../InkToLatex/InkToLatex/StarterTemplates.json")
try JSONEncoder().encode(templates).write(to: outURL)

print("Wrote \(templates.count) templates for \(countPerLabel.count) symbols to StarterTemplates.json")
let short = countPerLabel.filter { $0.value < perSymbol }.map { "\($0.key): \($0.value)" }.sorted()
if !short.isEmpty { print("Fewer than \(perSymbol) writers for: \(short.joined(separator: ", "))") }

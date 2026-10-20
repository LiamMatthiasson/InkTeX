# CLAUDE.md

Context for Claude Code sessions on this project. Read this first, then README.md
for how the web code works.

## The project

Ink to LaTeX: handwrite math on an iPad (Apple Pencil) and see it converted to LaTeX
live, without an LLM and without any server. Recognition runs entirely on the device,
so it's free, offline-capable, private, and fast. The owner is Liam, a student building
this partly to learn how it works.

There are two versions:
- **Web app** (repo root: `index.html`, `app.js`, `recognizer.js`, `styles.css`, `vendor/`),
  hosted on GitHub Pages: https://liammatthiasson.github.io/LaTex/
- **Native iPad app** (in progress, `InkToLatex/`: open `InkToLatex.xcodeproj`; Swift sources in `InkToLatex/InkToLatex/`, which Xcode includes automatically): SwiftUI + PencilKit. Liam moved to native
  because pen feel in Safari hit the browser's limits (latency, batched pointer events).
  The web app stays live as a demo.

## How Liam wants to work

- **Liam is learning.** He wrote most of the recognizer himself with guidance
  (`pathLength`, `resample`'s design, `translateToOrigin`, the matching ideas), and is now
  learning Swift. Explain *why* a change works, in plain language, not just what changed.
- When he asks how to do something conceptual, guide with questions and small hints
  rather than handing over the full answer. When he explicitly asks you to write the
  code, write it, then walk through the important parts.
- He's comfortable with basic JavaScript and new to Swift; keep explanations concrete
  (small numeric examples worked well, e.g. walking a 3-point stroke through a function).
- Keep changes small and focused, and keep his code and comments recognizable.

## Rules for editing (important)

- **Two Claude sessions have edited this folder at the same time** (Claude Code and a
  claude.ai chat). Each session's memory of a file can be stale, and writing from that
  stale copy silently erases the other's work. This has happened twice.
  **Always re-read a file from disk immediately before editing it**, and never
  reconstruct a whole file from memory.
- **On Oct 19, 2026 the entire LaTex folder was emptied** while an Xcode project was being
  created/saved (exact cause unknown; possibly saving over the folder). It was restored
  from GitHub, but uncommitted work was lost. **Commit and push often.** When saving
  Xcode projects, never name them the same as an existing folder, and never choose
  "Replace" in a save dialog.
- **Never run `git checkout -- <file>`, `git restore`, `git reset --hard`, or
  "discard changes"** unless Liam explicitly asks. Uncommitted changes may be work
  from the other session.
- **Bump the `?v=` number** on the `<script>` and stylesheet tags in `index.html`
  whenever web JS or CSS changes. Safari on iPad caches aggressively.

## Key design decisions (and why)

- **Recognition is $P point-cloud matching**, not an ML model or LLM. Started with
  bead-by-bead matching ($1-style, `pathDistance`); replaced with point clouds because
  stroke order and direction differ between drawings of the same symbol (e.g. `+`).
- **The recognizer stays pure**: no UI, storage or events (`recognizer.js`, and
  `InkToLatex/InkToLatex/Recognizer.swift`, a line-by-line port). Points in, ranked results out.
  `RecognizerChecks.swift` checks the Swift port against numbers produced by the
  JavaScript version; keep the two in sync.
- **Template labels are the LaTeX itself** (`2`, `+`, `\alpha`), so building the output is
  just sorting symbols left to right and joining labels with spaces.
- **Templates store raw strokes, never normalized shapes.** The normalized shape is
  recomputed in memory at load and on Save (`PreparedTemplate` in Swift). Changing
  `NUM_POINTS` or normalization then never invalidates saved templates. The Swift `Point`
  saves only `x`/`y` (its `stroke` field is excluded via CodingKeys), so template JSON is
  compatible between the web and native apps.
- **`recognize()` returns a ranked list, not just the winner.** The top 3 are meant for a
  future tap-to-correct menu.
- **Grouping strokes into symbols** (native app, `NoteModel`): a new stroke joins the
  previous symbol only if it starts within 1 s of the last pen-up, genuinely overlaps it
  horizontally (shared stretch >= 25% of the narrower width, thin strokes count as 6 pt),
  AND the joined strokes match some template well (best score < 1.5): recognition-driven
  grouping. The old rule (any overlap with 10 pt slack, still in the web app) chained fast
  handwriting into one giant "symbol". Recognition results are cached per symbol, so
  replays after undo/redo/erase are cheap.
- **Lines and the document** (`NoteModel.lines`, `lineLatex`, `document`): symbols are
  sorted by vertical center; a symbol joins the current line if its center is inside the
  line's vertical band (every line at least `minLineHeight` = 30 pt tall, so a line starting
  with "-" still works); each line reads left to right. Page coordinates run continuously
  across pages, so lines on page 2 follow page 1. The output is a complete document
  (`\documentclass{article}` + amsmath/amssymb), one `\[ ... \]` display equation per
  line. Copy copies the whole document; the panel renders each line with KaTeX.
- **Spatial re-ranking** (`Layout.swift`, pure logic): normalize() throws away size and
  position, so `applySpatialContext` brings them back per line to break ties between
  look-alikes (g/9, s/5, x-height letters vs digits). The line is measured ONLY from symbols
  the recognizer is confident about (top-2 gap >= `unsureMargin` 0.3); misread symbols would
  otherwise pollute the baseline. Baseline = median bottom of confident non-descender,
  non-floater symbols; size reference = median height of confident tall symbols (size rules
  are skipped without one, e.g. "x + y"). Only unsure symbols are re-ranked, only among their
  top 3, by adding `mismatchPenalty` per broken expectation. The same per-symbol measurements
  (relativeHeight, drop) are meant to drive superscripts/subscripts next. Liam wrote
  `median`, `measureLine` and `measure` himself.
- **Speed**: `greedyMatch`/`cloudDistance` use early abandoning against each label's best
  score so far; this keeps every label's best score exact (verified identical to the
  original on 2,000 random shapes). Run the app in the Release configuration when judging
  speed: Debug builds of this numeric code are far slower.
- **Web drawing engine**: two stacked canvases, coordinates from `clientX/Y` minus the
  cached canvas box (not `offsetX`), pointer capture, `getCoalescedEvents`,
  `getPredictedEvents`, perfect-freehand (vendored, MIT), `streamline` 0.15. Pointer rules:
  the Pencil always wins over a palm/finger; a new Pencil stroke recovers from a missed
  pen-up; canceled Pencil strokes are kept, canceled finger strokes dropped.
- **Native drawing**: PencilKit's `PKCanvasView` (`InkCanvas.swift`) does ink,
  pressure and palm rejection. `drawingPolicy = .default` follows the iPad's setting.
  New strokes are detected in `canvasViewDrawingDidChange`: one stroke appended means
  "recognize it"; anything else (undo, redo, eraser) means "replay every stroke"
  (`NoteModel.replaceStrokes`). Strokes are compared by creation date and point count.
  **Notebook pages** (`PageLayout`): US Letter-shaped pages (768 x 994 pt in page
  coordinates) stacked vertically with 28 pt gaps; one blank page always follows the last
  page with ink. `PageBackgroundView` (behind the transparent canvas) draws the desk,
  pages and grid, redrawn to match the canvas's zoom and scroll. "Fit" zoom = page width
  fills the screen; pinch zooms up to 4x from there.
  Two-finger double-tap = undo, three-finger double-tap = redo (`NoteCanvasView`
  turns off iPadOS's own three-finger edit gestures so they don't steal these).
  Hotbar tools: Pencil, Pen, Marker, Eraser (bitmap eraser), each with its own size.
- **Visual design**: an engineering computation pad (pale green grid paper), deep green
  accent, brick red for Erase. Pen hotbar at top (Pencil / Pen / Marker); Save and Undo
  bottom left; Show LaTeX and Erase bottom right. Same in both apps (`Theme.swift`
  mirrors `styles.css`).
- **Built-in starter templates**: `tools/convert.swift` (run on the Mac with
  `cd tools && swift convert.swift`) reads the HWRT dataset in `tools/hwrt/` (gitignored,
  ~1.3 GB; ODbL license, https://zenodo.org/records/50022) and writes
  `InkToLatex/InkToLatex/StarterTemplates.json`: 10 samples (different writers) of each of
  67 chosen symbols. HWRT's real columns are `symbol_id;user_id;data;user_agent`, data is
  JSON, lines end in CRLF, and user_agent contains `;` (split with maxSplits: 3). Measured on
  HWRT's test writers: 70% top-1, 88% top-3 (vs 64%/83% with 5 per symbol). Main confusions
  are true look-alikes (9/g, x/\times, a/\alpha, 5/s). The app loads starters first, then the
  user's own templates on top; only the user's are saved or undone.
- **Templates are per device.** Web: `localStorage`. Native: `templates.json` in the app's
  Documents folder. Real templates should be made on the iPad with the Pencil.

## Roadmap (in rough order)

1. Get the native app building and running (simulator, then iPad); tune pen feel.
2. **Export / Import templates** as `.json` (backup, moving templates between devices and
   between the web and native apps).
3. **Tap-to-correct**: tap a symbol, pick from the top-3 guesses; save the corrected
   drawing as a new template so it learns from use.
4. **Layout within a line**: superscripts, subscripts, fractions, square roots, using
   symbol size and position. The current grouping rule wrongly merges a fraction bar with
   its numerator, since they overlap horizontally.
5. Later: a starter template set, teaching moved into a settings screen, `.tex` export,
   handwritten text regions alongside math.

## Open questions Liam was working through

- Two vertical strokes (`11`) written quickly and less than 10 pt apart get merged into one
  symbol. What changes would fix that, and what would they break?

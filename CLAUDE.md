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
- **Native iPad app** (in progress, `swift/`): SwiftUI + PencilKit. Liam moved to native
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
  `swift/Recognizer.swift`, a line-by-line port). Points in, ranked results out.
  `swift/RecognizerChecks.swift` checks the Swift port against numbers produced by the
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
- **Grouping strokes into symbols**: a new stroke joins the previous symbol if it starts
  within 1 s of the last pen-up AND overlaps it horizontally (10 pt slack). The group is
  re-recognized each time it grows.
- **Web drawing engine**: two stacked canvases, coordinates from `clientX/Y` minus the
  cached canvas box (not `offsetX`), pointer capture, `getCoalescedEvents`,
  `getPredictedEvents`, perfect-freehand (vendored, MIT), `streamline` 0.15. Pointer rules:
  the Pencil always wins over a palm/finger; a new Pencil stroke recovers from a missed
  pen-up; canceled Pencil strokes are kept, canceled finger strokes dropped.
- **Native drawing**: PencilKit's `PKCanvasView` (`swift/InkCanvas.swift`) does ink,
  pressure and palm rejection. `drawingPolicy = .default` follows the iPad's setting.
  New strokes are detected in `canvasViewDrawingDidChange` by comparing stroke counts.
- **Visual design**: an engineering computation pad (pale green grid paper), deep green
  accent, brick red for Erase. Pen hotbar at top (Pencil / Pen / Marker); Save and Undo
  bottom left; Show LaTeX and Erase bottom right. Same in both apps (`swift/Theme.swift`
  mirrors `styles.css`).
- **Templates are per device.** Web: `localStorage`. Native: `templates.json` in the app's
  Documents folder. Real templates should be made on the iPad with the Pencil.

## Roadmap (in rough order)

1. Get the native app building and running (simulator, then iPad); tune pen feel.
2. **Export / Import templates** as `.json` (backup, moving templates between devices and
   between the web and native apps).
3. **Tap-to-correct**: tap a symbol, pick from the top-3 guesses; save the corrected
   drawing as a new template so it learns from use.
4. **Layout (2-D structure)**: superscripts, subscripts, fractions, square roots, using
   symbol size and position. The current grouping rule wrongly merges a fraction bar with
   its numerator, since they overlap horizontally.
5. Later: a starter template set, teaching moved into a settings screen, `.tex` export,
   handwritten text regions alongside math.

## Open questions Liam was working through

- Two vertical strokes (`11`) written quickly and less than 10 pt apart get merged into one
  symbol. What changes would fix that, and what would they break?

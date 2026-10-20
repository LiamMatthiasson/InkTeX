# Ink to LaTeX

Handwrite math on an iPad with an Apple Pencil and get LaTeX back, live. Recognition runs
entirely on the device: no LLM, no server, no account. That makes it free, private, fast,
and usable offline.

There are two versions of the app:

| Version | Where | Status |
|---------|-------|--------|
| **Web app** | Repo root (`index.html`, `app.js`, `recognizer.js`, `styles.css`, `vendor/`). Live at <https://liammatthiasson.github.io/LaTex/> | Working demo |
| **Native iPad app** | `InkToLatex/` (SwiftUI + PencilKit) | In progress, the main focus |

The project moved to a native app because pen feel in Safari ran into the browser's limits
(input latency, batched pointer events). The web app stays up as a demo.

## How recognition works

Both apps use the same recognizer: the **$P point-cloud recognizer** (Vatavu, Anthony &
Wobbrock, 2012). It's in `recognizer.js`, and `InkToLatex/InkToLatex/Recognizer.swift` is a
line-by-line Swift port of it.

1. **Flatten.** A symbol's strokes are joined into one list of points, each tagged with its stroke.
2. **Resample** to 32 evenly spaced points along the ink, skipping the gaps where the pen was lifted.
3. **Normalize.** Move the points so their center sits at the origin, then scale so the
   larger side of the bounding box is 1.
4. **Match.** Compare the drawing to each template as an unordered cloud of points: each
   point greedily claims the nearest unclaimed point in the other cloud, and the weighted
   distances are summed. Several starting points are tried in both directions and the best
   score is kept.

Because shapes are compared as clouds of points, stroke order and direction don't matter
(a `+` drawn vertical-first matches one drawn horizontal-first). `recognize()` returns a
ranked list of labels, lowest score first, not just the winner.

A few design choices worth knowing:

- **Template labels are the LaTeX itself** (`2`, `+`, `\alpha`), so building the output is
  just putting symbols in reading order and joining their labels with spaces.
- **Templates store raw strokes**, never normalized shapes. The normalized version is
  recomputed when templates load, so changing the resampling or normalization never breaks
  saved templates. Template JSON is the same format in both apps.
- **The recognizer is pure**: points in, ranked results out. No UI, storage or events.
  `RecognizerChecks.swift` checks the Swift port against numbers from the JavaScript version
  and prints ✅/❌ lines in Xcode's console at launch.
- **Early abandoning** makes matching fast: once a template's partial distance is already
  worse than the best score for its label, the rest of that comparison is skipped. Every
  label's best score stays exact.

## The native iPad app

Open `InkToLatex/InkToLatex.xcodeproj` in Xcode and run it on an iPad or the iPad
simulator. Swift sources live in `InkToLatex/InkToLatex/`, and Xcode includes new files
there automatically. When judging speed, use the **Release** configuration: Debug builds of
this numeric code are much slower.

### Using it

- **Write.** Each stroke is recognized when the pen lifts. A fresh install already reads
  digits, operators, letters and Greek, thanks to the built-in starter templates (see
  [Starter templates](#starter-templates-hwrt-dataset)).
- **Notebook pages.** The paper is a stack of letter-sized grid pages that scroll
  vertically; a blank page always follows the last one with ink. Pinch to zoom (up to 4x).
- **Tools.** The hotbar at the top has Pencil, Pen, Marker and Eraser, each with its own
  size slider. Ink, pressure and palm rejection come from PencilKit.
- **Undo / redo.** Two-finger double-tap undoes a stroke; three-finger double-tap redoes it.
- **Show LaTeX** opens a panel that renders each line with KaTeX and shows the full source.
  **Copy** copies a complete, compilable LaTeX document (`\documentclass{article}` with
  amsmath and amssymb, one `\[ ... \]` display equation per line), ready to paste into
  Overleaf.
- **Erase** clears the page.

### Teaching it your handwriting

Your own templates make recognition much better than the starters alone:

1. Write one symbol, for example a `2`.
2. Type its LaTeX in the label box: `2`, `+`, `x`, `\alpha`, `\int`, ...
3. Press **Save**. The drawing becomes a template and the page clears.

Save a few examples of each symbol. **Undo Save** removes your most recent template.
Templates are saved to `templates.json` in the app's Documents folder, so they belong to
that device. The built-in starters are never saved or undone.

### How the page is read

- **Strokes into symbols.** A new stroke joins the previous symbol only if all three hold:
  it starts within 1 second of the last pen-up, it genuinely overlaps the symbol
  horizontally (a shared stretch of at least 25% of the narrower width), and the combined
  strokes match some template well. Otherwise it starts a new symbol. Results are cached
  per symbol, so replaying the page after undo, redo or erasing is cheap.
- **Symbols into lines.** Symbols are sorted by their vertical center. A symbol joins the
  current line if its center falls inside that line's vertical band (every line is at least
  30 pt tall, so a line starting with `-` still works). Each line reads left to right, and
  lines continue across pages.

### Files

```
InkToLatex/InkToLatex/
  MyApp.swift              App entry point
  ContentView.swift        The screen: pen hotbar, teach controls, LaTeX panel
  InkCanvas.swift          PencilKit canvas, notebook pages, undo/redo gestures, stroke detection
  NoteModel.swift          Templates, grouping strokes into symbols and lines, building the document
  Recognizer.swift         $P recognizer (port of recognizer.js)
  RecognizerChecks.swift   Checks the Swift port against the JavaScript version
  LatexView.swift          Renders each line with KaTeX in a small web view
  Theme.swift              Colors, grid paper and button styles (mirrors styles.css)
  StarterTemplates.json    Built-in templates generated from the HWRT dataset
```

## The web app

Live at <https://liammatthiasson.github.io/LaTex/>. It has no build step and no
dependencies to install. It's built for Safari on an iPad with an Apple Pencil, and also
works with a mouse or a finger.

To run it locally, serve the folder over HTTP (browsers block ES module imports from
`file://` pages, and `vendor/perfect-freehand.mjs` is one):

```sh
python3 -m http.server 8000
```

Then open <http://localhost:8000>, or `http://<your-computer's-LAN-IP>:8000` from an iPad on
the same network. KaTeX and the Overpass font load from CDNs, so the first load needs an
internet connection. If perfect-freehand fails to load, the app still works but draws plain
lines.

The web app has no starter templates: teach it with **Save** and a label, as above.
Templates are kept in the browser's `localStorage`. Pens are Pencil (`1`), Pen (`2`) and
Marker (`3`); the pen only changes how ink looks, since recognition rescales every drawing.
Its grouping rule is the older, simpler one: a stroke joins the previous symbol if it starts
within 1 second and overlaps it horizontally. The output is a single line read left to right.

Under the hood it draws on two stacked canvases (`#ink` for finished strokes, `#live` for
the stroke in progress), uses `getCoalescedEvents()` and `getPredictedEvents()` to capture
the Pencil's full ~240 Hz input, and smooths strokes with perfect-freehand. Once it sees an
Apple Pencil, the Pencil always wins over palm and finger touches.

```
index.html          Page structure: pen hotbar, two canvases, LaTeX panel, toolbar
styles.css          Grid-paper look and layout
app.js              Drawing, pointer input, pens, symbol grouping, templates, LaTeX output
recognizer.js       $P recognizer: flatten, resample, normalize, cloud matching
vendor/             perfect-freehand (MIT), for smooth pressure-sensitive strokes
```

When changing web JS or CSS, bump the `?v=` numbers on the tags in `index.html`, because
Safari on iPad caches aggressively.

## Starter templates (HWRT dataset)

The native app's built-in templates come from the **HWRT database of handwritten
mathematical symbols** by Martin Thoma. `tools/convert.swift` reads the dataset and keeps
10 samples, each from a different writer, of 67 symbols chosen for math notes: digits,
operators and relations, brackets, lowercase letters, Greek letters, and calculus symbols
and arrows. It writes them to `InkToLatex/InkToLatex/StarterTemplates.json`. Measured on
the dataset's separate test writers, the starters alone recognize 70% of symbols correctly
on the first guess and 88% within the top 3. The main confusions are true look-alikes
(`9`/`g`, `x`/`\times`, `a`/`\alpha`, `5`/`s`).

To regenerate the starters:

1. Download the dataset from <https://zenodo.org/records/50022> and extract it into
   `tools/hwrt/` so that it contains `symbols.csv`, `train-data.csv` and `test-data.csv`.
   It's about 1.3 GB, so it is gitignored and not part of this repo.
2. Run, on the Mac:

   ```sh
   cd tools
   swift convert.swift
   ```

To change which symbols are included, or how many samples of each, edit `wanted` and
`perSymbol` at the top of `convert.swift`.

## Roadmap

1. Get the native app running well on the iPad and tune pen feel.
2. Export and import templates as `.json` (backups, moving between devices and between the
   two apps).
3. Tap-to-correct: tap a symbol, pick from the top-3 guesses, and save the correction as a
   new template so the app learns from use.
4. Layout within a line: superscripts, subscripts, fractions and square roots, using symbol
   size and position.
5. Later: `.tex` export, a settings screen, and handwritten text alongside math.

## Credits

- **HWRT dataset**: Martin Thoma, *HWRT database of handwritten mathematical symbols*,
  <https://zenodo.org/records/50022>, licensed under the
  [Open Database License (ODbL) v1.0](https://opendatacommons.org/licenses/odbl/1-0/).
  `StarterTemplates.json` is derived from it (a subset of its samples, with timestamps
  removed) and is shared under the same license. See also M. Thoma, *On-line Recognition
  of Handwritten Mathematical Symbols*, bachelor's thesis, Karlsruhe Institute of
  Technology, 2014 ([arXiv:1511.09030](https://arxiv.org/abs/1511.09030)).
- **$P recognizer**: Vatavu, R.-D., Anthony, L., Wobbrock, J. O. *Gestures as Point
  Clouds: A $P Recognizer for User Interface Prototypes*. ICMI 2012.
- [**perfect-freehand**](https://github.com/steveruizok/perfect-freehand) by Steve Ruiz,
  MIT License (see `vendor/perfect-freehand-LICENSE.txt`), for the web app's ink.
- [**KaTeX**](https://katex.org) for rendering LaTeX in both apps.
- Apple's **PencilKit** for the native app's ink and palm rejection.

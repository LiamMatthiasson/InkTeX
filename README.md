# Ink to LaTeX

Handwrite math on an iPad with an Apple Pencil and get LaTeX back, live. Recognition runs
entirely on the device: no LLM, no server, no account. It's free, private, fast, and works
offline.



https://github.com/user-attachments/assets/80100cd4-43c2-45c5-b3e4-abcf7f192611


| Version | Where | Status |
|---------|-------|--------|
| **Native iPad app** | `InkToLatex/` (SwiftUI + PencilKit) | Main focus |
| **Web app** | Repo root. Live at <https://liammatthiasson.github.io/LaTex/> | Demo, simpler |

The project moved to a native app because pen feel in Safari hit the browser's limits
(input latency, batched pointer events).

## The native iPad app

Open `InkToLatex/InkToLatex.xcodeproj` in Xcode and run on an iPad or the iPad simulator.
Use the **Release** configuration when judging speed; Debug builds of the numeric code
are much slower.

### Using it

- **Write.** Strokes are recognized as you write. A fresh install already reads digits,
  operators, letters, Greek and calculus symbols from the built-in starter templates.
- **Notebook.** Letter-sized grid pages scroll vertically, with a blank page always after
  the last one with ink. Pinch to zoom up to 4x.
- **Tools.** Pencil, Pen, Marker and Eraser in the top hotbar, each with its own size.
- **Undo / redo.** Two-finger double-tap undoes, three-finger double-tap redoes.
- **Notes.** Create, rename, switch and delete notes. They autosave a second after you
  stop writing and when you leave the app.
- **Split View** opens the LaTeX panel beside the notebook (drag the handle to resize).
  It shows each symbol as a chip, the typeset document, and its source. **Copy** copies a
  complete, compilable document, ready for Overleaf.
- **Erase** clears the note (after confirming).

### Teaching and correcting

- **Teach:** write a symbol, type its LaTeX (`2`, `x`, `\alpha`, `\int`) and tap **Teach**.
  The last symbol on the page becomes a template; the ink stays. Labels are the symbol
  itself: `2`, not `^2`. Raised or lowered comes from where you write it.
- **Correct:** tap any chip in the LaTeX panel to pick one of the top 3 guesses or type
  another. Unsure symbols are tinted. Corrections are saved as templates too, along with
  what the recognizer wrongly guessed.
- **Templates** lists everything you've taught, with a picture of each, to delete or
  rename. **Undo Teach** removes the latest one.

Your templates are saved to `templates.json` in the app's Documents folder, so they're per
device. Starter templates are never changed.

### How a page is read

1. **Strokes → symbols.** A stroke joins the previous symbol if it starts within 1 s of
   the last pen-up (or crosses it), overlaps it horizontally by at least 25% of the
   narrower width, and the combined strokes match some template well. A fraction bar never
   joins the symbol above or below it. Recognition runs in the background, one stroke at a
   time, in order; results are cached, so undo/redo replays are cheap.
2. **Recognition.** Each symbol is matched against the templates ($P, below).
3. **Fractions.** A wide `-` with symbols right above and below becomes `\frac{…}{…}`,
   nested fractions included.
4. **Lines.** Symbols are grouped into lines by vertical position (tallest first, so a
   small raised `²` joins its line instead of starting a new one), each read left to right.
5. **Scripts and limits.** A symbol smaller than expected next to its base is a
   superscript or subscript ("expected", because the `x` in `2x` is small but not a
   script). Limits on `∫ ∑ ∏ ∮` are found by position.
6. **Re-ranking look-alikes.** Shape matching ignores size and position, so for symbols
   the recognizer is unsure about, the line's baseline and size break ties: `g` vs `9`,
   `s` vs `5`, small letters vs digits.
7. **Text or math.** Apple's Vision framework also reads each line as handwriting (on
   device). Symbols under a confidently read word become text, the rest inline math:
   "the area is x²" becomes `the area is $x^{2}$`. Lines without words become display
   equations `\[ … \]`. The ƒ/¶ button on each row overrides the choice.

### Files

```
InkToLatex/InkToLatex/
  MyApp.swift              App entry point
  ContentView.swift        The screen: hotbar, toolbar, notes list, LaTeX panel, chips
  InkCanvas.swift          PencilKit canvas, notebook pages, zoom, undo/redo gestures
  NoteModel.swift          Templates, stroke queue, grouping strokes into symbols, the document
  Layout.swift             Lines, fractions, scripts, limits, spatial re-ranking (pure logic)
  TextLines.swift          Vision text reading, mixing text and inline math, escaping
  Recognizer.swift         $P recognizer (port of recognizer.js)
  RecognizerChecks.swift   Checks the Swift port against the JavaScript version
  LatexView.swift          Typesets the document with KaTeX in a web view
  NoteStore.swift          Saving notes: Documents/Notes/notes.json + <id>.drawing
  TemplatesView.swift      The Templates screen
  Theme.swift              Colors, grid paper, button styles (mirrors styles.css)
  StarterTemplates.json    Built-in templates from the HWRT dataset
```

Only ink is saved; opening a note replays its strokes, so the LaTeX always reflects your
current templates. `NoteModel.debugLogging` prints how each page was read to Xcode's
console. The LaTeX panel loads KaTeX from a CDN; offline it shows the raw LaTeX.

## How recognition works

Both apps use the **$P point-cloud recognizer** (Vatavu, Anthony & Wobbrock, 2012):
`recognizer.js`, ported line by line to `Recognizer.swift`.

1. **Flatten** a symbol's strokes into one list of points, each tagged with its stroke.
2. **Resample** to 32 evenly spaced points along the ink, skipping pen-up gaps.
3. **Normalize**: center at the origin and scale the larger side to 1.
4. **Match** against each template as unordered point clouds: each point greedily claims
   the nearest unclaimed point in the other cloud, from several starts in both directions,
   keeping the best score.

Because shapes are compared as clouds, stroke order and direction don't matter.
`recognize()` returns a ranked list (lowest score first), which feeds the correction menu
and the re-ranking.

- **Labels are the LaTeX itself**, so output is mostly joining labels in order.
- **Templates store raw strokes**, never normalized shapes, so changing resampling or
  normalization never breaks saved templates. The JSON format is the same in both apps.
- **The recognizer is pure**: points in, ranked results out. `RecognizerChecks.swift`
  prints lines at launch comparing the Swift port with numbers from the JS version.
- **Early abandoning** skips the rest of a comparison once it's worse than that label's
  best so far; every label's best score stays exact.

## The web app

Live at <https://liammatthiasson.github.io/LaTex/>. No build step or dependencies. Built
for Safari on iPad with an Apple Pencil; also works with a mouse or finger.

To run it locally, serve the folder over HTTP (ES modules don't load from `file://`):

```sh
python3 -m http.server 8000
```

Then open <http://localhost:8000>, or `http://<your-Mac's-LAN-IP>:8000` from an iPad on
the same network. KaTeX and the font load from CDNs.

It's a simpler version: no starter templates (teach it with **Save** and a label; templates
live in `localStorage`), the older grouping rule (within 1 s and any horizontal overlap),
and a single line of output with no scripts, fractions or text. Ink is drawn on two
stacked canvases with coalesced and predicted pointer events and smoothed by
perfect-freehand; the Pencil always wins over palm and finger touches.

```
index.html          Page structure
styles.css          Grid-paper look and layout
app.js              Drawing, pointer input, pens, grouping, templates, LaTeX output
recognizer.js       $P recognizer
vendor/             perfect-freehand (MIT)
```

When changing web JS or CSS, bump the `?v=` numbers in `index.html`: Safari on iPad
caches aggressively.

## Starter templates (HWRT dataset)

`tools/convert.swift` builds `StarterTemplates.json` from the **HWRT database of
handwritten mathematical symbols** (Martin Thoma): 10 samples, each from a different
writer, of 68 symbols chosen for math notes. On the dataset's separate test writers, the
starters alone get 70% right on the first guess and 88% within the top 3. The main
confusions are true look-alikes (`9`/`g`, `x`/`\times`, `a`/`\alpha`, `5`/`s`).

To regenerate:

1. Download the dataset from <https://zenodo.org/records/50022> and extract it into
   `tools/hwrt/` (`symbols.csv`, `train-data.csv`, `test-data.csv`; ~1.3 GB, gitignored).
2. On the Mac: `cd tools && swift convert.swift`

Edit `wanted` and `perSymbol` at the top of `convert.swift` to change the set.

## Roadmap

- Export / import templates as `.json` (backups, moving between devices and apps).
- Square roots and more layout.
- Save per-line math/text overrides with the note.
- `.tex` file export and a settings screen.
- a CNN classifier (PyTorch-trained, forward pass in Swift)

## Credits

- **HWRT dataset**: Martin Thoma, *HWRT database of handwritten mathematical symbols*,
  <https://zenodo.org/records/50022>, [ODbL v1.0](https://opendatacommons.org/licenses/odbl/1-0/).
  `StarterTemplates.json` is derived from it (a subset of samples, timestamps removed) and
  shared under the same license. See also M. Thoma, *On-line Recognition of Handwritten
  Mathematical Symbols*, KIT, 2014 ([arXiv:1511.09030](https://arxiv.org/abs/1511.09030)).
- **$P recognizer**: Vatavu, R.-D., Anthony, L., Wobbrock, J. O. *Gestures as Point
  Clouds: A $P Recognizer for User Interface Prototypes*. ICMI 2012.
- [**perfect-freehand**](https://github.com/steveruizok/perfect-freehand) by Steve Ruiz,
  MIT (`vendor/perfect-freehand-LICENSE.txt`).
- [**KaTeX**](https://katex.org) for rendering LaTeX; Apple's **PencilKit** and
  **Vision** in the native app.

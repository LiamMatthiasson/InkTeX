# Ink to LaTeX

Handwrite math on a grid-paper canvas and get LaTeX back. You teach the app your own handwriting by saving labeled examples. It then recognizes what you write by matching it against those examples and renders the result with KaTeX.

It runs entirely in the browser: no build step, no server-side code, no dependencies to install. It's built for an iPad with an Apple Pencil, and it also works with a mouse or a finger.

## Running it

The app loads `vendor/perfect-freehand.mjs` as an ES module, and browsers block module imports from `file://` pages. Serve the folder over HTTP instead of opening `index.html` directly:

```sh
python3 -m http.server 8000
```

Then open <http://localhost:8000>. To use it on an iPad, open `http://<your-computer's-LAN-IP>:8000` from Safari on the same network.

If perfect-freehand fails to load, the app still works but draws plain lines.

KaTeX and the Overpass font load from CDNs, so the first load needs an internet connection.

## How to use it

### 1. Teach it your handwriting

The recognizer starts with nothing to recognize. Before it can read anything, you need to save some templates:

1. Write one symbol on the paper, for example a `2`.
2. Type the LaTeX for it in the label box: `2`, `+`, `x`, `\alpha`, `\int`, and so on.
3. Press **Save**. The drawing is stored as a template and the paper clears.

Save several examples of each symbol (around three) so it copes with natural variation. **Undo** removes the most recently saved template.

Templates are kept in the browser's `localStorage`, so they persist between visits but belong to that one browser on that one device.

### 2. Write math

Once templates exist, every stroke is recognized when you lift the pen:

- A stroke that starts within 1 second of the previous one *and* overlaps it horizontally joins that symbol. That's how the two lines of `+`, `=` or `4` group together. Otherwise the stroke starts a new symbol.
- Symbols are read left to right and joined with spaces into a single LaTeX string.

Press **Show LaTeX** to open the panel with the rendered math and its source. **Copy** puts the source on your clipboard. **Erase** clears the page.

### Pens

| Pen    | Key | Look                               |
|--------|-----|------------------------------------|
| Pencil | `1` | Thin, gray, very pressure-sensitive |
| Pen    | `2` | Fineliner, navy (default)          |
| Marker | `3` | Thick, nearly even width           |

The pen only changes how strokes look. Recognition rescales every drawing, so it is unaffected. The app remembers your last pen.

### Palm rejection

Once the app sees an Apple Pencil, it ignores finger and palm touches for the rest of the session. Only one pointer draws at a time, and strokes the system cancels (for example, ones it decides were a palm) are discarded.

## How recognition works

`recognizer.js` is an implementation of the **$P point-cloud recognizer** (Vatavu, Anthony & Wobbrock, 2012):

1. **Flatten.** A symbol's strokes are joined into one list of points, each tagged with its stroke.
2. **Resample** to 32 evenly spaced points along the ink. The gaps where the pen was lifted are skipped.
3. **Normalize.** The points are moved so their center sits at the origin, then scaled so the larger side of the bounding box is 1.
4. **Match.** The drawing is compared to each template as an unordered cloud of points: each point greedily claims the nearest unclaimed point in the other cloud, and the weighted distances are summed. Several starting points are tried in both directions, and the best score is kept.

Because the shapes are treated as clouds of points, stroke order and direction don't matter. The label with the lowest score wins, and the full ranked list is logged to the console.

## Project layout

```
index.html          Page structure: pen hotbar, two canvases, LaTeX panel, toolbar
styles.css          Grid-paper look and layout
app.js              Drawing, pointer input, pens, symbol grouping, templates, LaTeX output
recognizer.js       $P recognizer: flatten, resample, normalize, cloud matching
vendor/             perfect-freehand (MIT), for smooth pressure-sensitive strokes
```

Drawing uses two stacked canvases. `#ink` holds finished strokes and `#live` redraws only the stroke in progress, once per animation frame. It uses `getCoalescedEvents()` to capture the Pencil's full ~240 Hz input.

## Limitations

- Layout is a single line read left to right. Superscripts, fractions and other 2-D structure aren't detected yet.
- Templates can't be exported, imported, or synced between devices.
- Only the most recent template can be removed with Undo. To start over, clear the site's storage.

## Credits

- [perfect-freehand](https://github.com/steveruizok/perfect-freehand) by Steve Ruiz, MIT License (see `vendor/perfect-freehand-LICENSE.txt`)
- [KaTeX](https://katex.org) for rendering LaTeX
- $P recognizer: Vatavu, R.-D., Anthony, L., Wobbrock, J. O. *Gestures as Point Clouds: A $P Recognizer for User Interface Prototypes*. ICMI 2012.

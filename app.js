// ===================== Ink: two canvas layers =====================
// #ink (bottom) holds finished strokes. #live (top) shows only the stroke being
// drawn, cleared and redrawn every frame, so a line is never painted over itself.
const canvas = document.getElementById('ink');
const ctx = canvas.getContext('2d');
const liveCanvas = document.getElementById('live');
const liveCtx = liveCanvas.getContext('2d');

const strokes = [];        // recognition data: each stroke is a list of { x, y, t, p }
const inkStrokes = [];     // what's on the page: { points, pen, realPressure }, for redrawing
let currentStroke = [];    // points of the stroke being drawn right now
let currentRealPressure = false;   // true when drawing with an Apple Pencil
let activePointer = null;  // id of the one pointer allowed to draw right now
let penSeen = false;       // once a Pencil is used, finger and palm touches are ignored

// perfect-freehand turns points into a smooth, pressure-sensitive outline.
// It loads in the background; until it arrives, strokes are drawn as plain lines.
let getStroke = null;
import('./vendor/perfect-freehand.mjs')
  .then((module) => { getStroke = module.getStroke; redrawAll(); })
  .catch((err) => console.warn('perfect-freehand did not load, using plain lines', err));

// Make each canvas's pixel grid match the screen exactly (sharp on Retina/iPad).
// Runs at startup and whenever the window size changes (rotation, Safari's toolbar).
function resizeCanvases() {
  const dpr = window.devicePixelRatio || 1;
  for (const [c, context] of [[canvas, ctx], [liveCanvas, liveCtx]]) {
    const box = c.getBoundingClientRect();
    c.width = Math.round(box.width * dpr);
    c.height = Math.round(box.height * dpr);
    context.setTransform(dpr, 0, 0, dpr, 0, 0);   // draw in normal page coordinates
  }
  redrawAll();   // resizing a canvas wipes it, so paint the strokes back
}

// The pen position measured from the canvas's own corner, no matter what
// element is under the pen (this is what fixes the lines from the corner).
function pointFromEvent(e) {
  const box = liveCanvas.getBoundingClientRect();
  return { x: e.clientX - box.left, y: e.clientY - box.top, t: e.timeStamp, p: e.pressure };
}

// Turn perfect-freehand's outline (a ring of points) into a smooth shape
function outlineToPath(outline) {
  const path = new Path2D();
  if (outline.length === 0) return path;
  path.moveTo(outline[0][0], outline[0][1]);
  for (let i = 0; i < outline.length; i++) {
    const [x0, y0] = outline[i];
    const [x1, y1] = outline[(i + 1) % outline.length];
    path.quadraticCurveTo(x0, y0, (x0 + x1) / 2, (y0 + y1) / 2);   // curve through midpoints
  }
  path.closePath();
  return path;
}

// Draw one stroke onto a canvas
function drawStroke(context, points, penName, realPressure, finished) {
  if (points.length === 0) return;
  const pen = PENS[penName];
  context.fillStyle = pen.color;
  context.strokeStyle = pen.color;

  if (getStroke) {
    const outline = getStroke(points.map((p) => [p.x, p.y, p.p]), {
      size: pen.size,
      thinning: pen.thinning,
      smoothing: 0.5,
      streamline: 0.4,
      simulatePressure: !realPressure,   // mouse/finger: fake pressure from speed
      last: finished,                    // finished strokes get proper end caps
    });
    context.fill(outlineToPath(outline));
  } else {
    context.lineWidth = pen.size * 0.75;   // fallback: one plain line, drawn once
    context.beginPath();
    context.moveTo(points[0].x, points[0].y);
    for (const p of points) context.lineTo(p.x, p.y);
    context.stroke();
  }
}

// Repaint every finished stroke (after a resize, or once perfect-freehand loads)
function redrawAll() {
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  for (const s of inkStrokes) drawStroke(ctx, s.points, s.pen, s.realPressure, true);
}

// Draw the live stroke at most once per screen refresh
let frameRequested = false;
function scheduleLiveDraw() {
  if (frameRequested) return;
  frameRequested = true;
  requestAnimationFrame(() => {
    frameRequested = false;
    liveCtx.clearRect(0, 0, liveCanvas.width, liveCanvas.height);
    drawStroke(liveCtx, currentStroke, currentPen, currentRealPressure, false);
  });
}

window.addEventListener('resize', resizeCanvases);
resizeCanvases();

// ===================== Pointer input =====================

liveCanvas.addEventListener('pointerdown', (e) => {
  if (e.pointerType === 'pen') penSeen = true;
  if (e.pointerType === 'touch' && penSeen) return;   // palm rejection
  if (activePointer !== null) return;                 // someone is already drawing

  activePointer = e.pointerId;
  try {
    liveCanvas.setPointerCapture(e.pointerId);        // keep this pointer's events, even over the toolbar
  } catch (err) {
    // Capture can fail if the pointer already lifted; drawing still works without it
  }
  currentRealPressure = e.pointerType === 'pen';
  currentStroke = [pointFromEvent(e)];
  scheduleLiveDraw();
});

liveCanvas.addEventListener('pointermove', (e) => {
  if (e.pointerId !== activePointer) return;          // hovering, or a different finger

  // The Pencil reports ~240 positions a second, but pointermove fires ~60 times.
  // getCoalescedEvents() hands over the in-between positions too.
  let samples = e.getCoalescedEvents ? e.getCoalescedEvents() : [];
  if (samples.length === 0) samples = [e];            // some browsers return an empty list
  for (const sample of samples) currentStroke.push(pointFromEvent(sample));
  scheduleLiveDraw();
});

// The system can cancel a touch (e.g. it decided it was a palm): throw that stroke away
liveCanvas.addEventListener('pointercancel', (e) => {
  if (e.pointerId !== activePointer) return;
  activePointer = null;
  currentStroke = [];
  liveCtx.clearRect(0, 0, liveCanvas.width, liveCanvas.height);
});

liveCanvas.addEventListener('pointerup', (e) => {
    if (e.pointerId !== activePointer) return;
    activePointer = null;

    // Move the finished stroke from the live layer to the page
    // (no extra point here: a lifting Pencil reports pressure 0, which would pinch the end)
    inkStrokes.push({ points: currentStroke, pen: currentPen, realPressure: currentRealPressure });
    drawStroke(ctx, currentStroke, currentPen, currentRealPressure, true);
    liveCtx.clearRect(0, 0, liveCanvas.width, liveCanvas.height);

    strokes.push(currentStroke);
    
    if (templates.length === 0) return;                // nothing to recognize against yet

    // Grouping: does this stroke belong to the symbol written just before it?
    // Yes if it started soon after the last stroke AND overlaps it left-to-right
    // (the two lines of a "+", "=" or "4"). Otherwise it starts a new symbol.
    const last = symbols[symbols.length - 1];
    const quick = currentStroke[0].t - lastPenUp < GROUP_TIME_MS;
    lastPenUp = e.timeStamp;

    let group;
    if (last && quick && overlapsX(last.strokes, [currentStroke])) {
        last.strokes.push(currentStroke);              // same symbol: add this stroke to it
        group = last;
    } else {
        group = { strokes: [currentStroke], label: '', x: 0 };   // a new symbol
        symbols.push(group);
    }

    // (Re)recognize the whole group, so a "-" becomes a "+" once its second line arrives
    const results = recognize(group.strokes, templates);
    group.label = results[0].label;
    group.x = xRange(group.strokes).min;
    updateLatex();
    console.log(results);
});

// ---------- Grouping helpers ----------
const GROUP_TIME_MS = 1000;   // a stroke started within 1s of the previous one may join it
const GROUP_MARGIN = 10;      // px of slack when checking overlap
let lastPenUp = 0;

// Leftmost and rightmost x across a list of strokes
function xRange(strokeList) {
  let min = Infinity, max = -Infinity;
  for (const stroke of strokeList) {
    for (const p of stroke) {
      min = Math.min(min, p.x);
      max = Math.max(max, p.x);
    }
  }
  return { min, max };
}

// Do two sets of strokes overlap horizontally (with a little slack)?
function overlapsX(a, b) {
  const ra = xRange(a);
  const rb = xRange(b);
  return rb.min <= ra.max + GROUP_MARGIN && rb.max >= ra.min - GROUP_MARGIN;
}

// ---------- Templates ----------

const saved = localStorage.getItem('templates');
const templates = saved ? JSON.parse(saved) : [];

for (let i = 0; i < templates.length; i++) {
  templates[i].shape = normalize(flatten(templates[i].strokes));   // all strokes, as one cloud
}

// Save only the raw data (label + strokes), never the computed shape
function saveTemplates() {
  const rawOnly = templates.map(t => ({ label: t.label, strokes: t.strokes }));
  localStorage.setItem('templates', JSON.stringify(rawOnly));
}

const statusBox = document.getElementById('status');
const labelBox = document.getElementById('label');

function showStatus() {
    statusBox.textContent = `${templates.length} templates saved`;
}
showStatus();


function clearDrawing() {
    ctx.clearRect(0, 0, canvas.width, canvas.height);  // erase what you see
    strokes.length = 0; 
    inkStrokes.length = 0;
    symbols.length = 0;
    updateLatex();                               // forget what the program remembers
}

document.getElementById('clear').addEventListener('click', clearDrawing);
document.getElementById('save').addEventListener('click', () => {
    const label = labelBox.value.trim();               // the label is the LaTeX for this symbol
    if (label === '' || strokes.length === 0) return;  

    const newStrokes = [...strokes];                 // a copy, so Erase can't empty it
    templates.push({
        label: label,
        strokes: newStrokes,
        shape: normalize(flatten(newStrokes)),         // all strokes, normalized once, right now
    });
    saveTemplates();

    clearDrawing();
    statusBox.textContent = `Saved "${label}" (${templates.length} total)`;
});

document.getElementById('undo').addEventListener('click', () => {
  if (templates.length === 0) return;                           // nothing to undo

  const removed = templates.pop();                              // take off the last one
  saveTemplates();
  statusBox.textContent = `Removed "${removed.label}" (${templates.length} total)`;
});

const symbols = [];   // recognized symbols: { label, x, strokes }

function updateLatex() {
  const ordered = [...symbols].sort((a, b) => a.x - b.x);   // left to right
  const latex = ordered.map(s => s.label).join(' ');

  const rendered = document.getElementById('latex');
  const code = document.getElementById('latex-code');

  if (latex === '') {
    rendered.textContent = 'Write something…';
    code.textContent = '';
    return;
  }
  katex.render(latex, rendered, { throwOnError: false, displayMode: true });
  code.textContent = latex;
}

// ---------- Show / hide the LaTeX panel ----------
const previewPanel = document.getElementById('preview');
const toggleButton = document.getElementById('toggle-preview');

toggleButton.addEventListener('click', () => {
  previewPanel.hidden = !previewPanel.hidden;   // flip: shown <-> hidden
  toggleButton.textContent = previewPanel.hidden ? 'Show LaTeX' : 'Hide LaTeX';
});

// ---------- Copy the LaTeX code ----------
document.getElementById('copy-latex').addEventListener('click', () => {
  const code = document.getElementById('latex-code').textContent;
  if (code === '') { statusBox.textContent = 'Nothing to copy yet'; return; }
  navigator.clipboard.writeText(code)
    .then(() => { statusBox.textContent = 'Copied LaTeX'; })
    .catch(() => { statusBox.textContent = 'Copy failed: select the code and copy it manually'; });
});

// ---------- Pens ----------
// Each pen has its own size, pressure response (thinning) and ink color. This only
// changes how strokes LOOK: normalize() rescales every drawing, so recognition is unaffected.
const PENS = {
  pencil: { size: 3,   thinning: 0.65, color: '#5A6472' },   // thin, very pressure-sensitive
  pen:    { size: 4.5, thinning: 0.5,  color: '#1F3A68' },   // like a fineliner
  marker: { size: 10,  thinning: 0.1,  color: '#1C2B22' },   // thick, nearly even width
};
let currentPen = 'pen';

function selectPen(name) {
  currentPen = name;
  document.querySelectorAll('.pen').forEach(button => {
    button.setAttribute('aria-pressed', button.dataset.pen === name);  // highlights the chosen one
  });
  try { localStorage.setItem('pen', name); } catch (e) {}   // remember it for next time
}

document.querySelectorAll('.pen').forEach(button => {
  button.addEventListener('click', () => selectPen(button.dataset.pen));
});

// Keys 1, 2, 3 switch pens (but not while typing a label)
window.addEventListener('keydown', (e) => {
  if (e.target === labelBox) return;
  const keys = { '1': 'pencil', '2': 'pen', '3': 'marker' };
  if (keys[e.key]) selectPen(keys[e.key]);
});

let lastPen = null;
try { lastPen = localStorage.getItem('pen'); } catch (e) {}
selectPen(PENS[lastPen] ? lastPen : 'pen');

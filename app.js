const canvas = document.getElementById('ink');
const dpr = window.devicePixelRatio || 1;  
canvas.width = canvas.clientWidth * dpr;
canvas.height = canvas.clientHeight * dpr;
const ctx = canvas.getContext('2d');
ctx.scale(dpr, dpr);
ctx.lineWidth = 4;
ctx.lineCap = 'round'; 
ctx.lineJoin = 'round';

const strokes = [];   // all finished strokes
let isWriting = false;     // are we currently drawing?
let currentStroke = [];    // points of the stroke being drawn right now

canvas.addEventListener('pointerdown', (e) => {
    isWriting = true;
    currentStroke = [];                                  // start a fresh list
    currentStroke.push({ x: e.offsetX, y: e.offsetY, t: e.timeStamp });

    ctx.lineWidth = PENS[currentPen].width;              // this pen's thickness...
    ctx.strokeStyle = PENS[currentPen].color;            // ...and ink color
    ctx.beginPath();                                     // start a new line on the canvas
    ctx.moveTo(e.offsetX, e.offsetY);                    // put the "pen" here without drawing
});

canvas.addEventListener('pointermove', (e) => {
    if (!isWriting) return;                              

    currentStroke.push({ x: e.offsetX, y: e.offsetY, t: e.timeStamp });

    ctx.lineTo(e.offsetX, e.offsetY);                    // draw a line to the new point
    ctx.stroke();                                        // actually paint it
});

canvas.addEventListener('pointerup', (e) => {
    if (!isWriting) return;
    isWriting = false;

    currentStroke.push({ x: e.offsetX, y: e.offsetY, t: e.timeStamp });
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
// Each pen has its own thickness and ink color. This only changes how
// strokes LOOK: normalize() rescales every drawing, so recognition is unaffected.
const PENS = {
  pencil: { width: 1.75, color: '#5A6472' },
  pen:    { width: 3.5,  color: '#1F3A68' },
  marker: { width: 7,    color: '#1C2B22' },
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

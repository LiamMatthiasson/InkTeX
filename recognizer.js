const NUM_POINTS = 32;

// A symbol can be several strokes (a "+" is two). flatten() joins them into one
// list of points, tagging each point with the stroke it came from (id).
function flatten(strokes) {
  const points = [];
  for (let s = 0; s < strokes.length; s++) {
    for (const p of strokes[s]) {
      points.push({ x: p.x, y: p.y, id: s });
    }
  }
  return points;
}

function pathLength(points) {
  let total = 0;

  for (let i = 1; i < points.length; i++) {
    if (points[i].id !== points[i-1].id) continue;   // pen was lifted here: not part of the path
    const dx = points[i].x - points[i-1].x;
    const dy = points[i].y - points[i-1].y;
    total += Math.hypot(dx,dy);
  }
  return total;
}


function resample(points, n) {
  const length = pathLength(points);

  // Safety check 1: a single tap (a dot, like the dot on an "i") has length 0.
  // Without this, beadDistance would be 0 and the loop below would never end.
  if (length === 0) {
    return Array.from({ length: n }, () => ({ x: points[0].x, y: points[0].y }));
  }

  const beadDistance = length / (n - 1);

  const beads = [{ x: points[0].x, y: points[0].y }];  // first bead = start point
  let walked = 0;                 // distance from the start of the stroke
  let nextBead = beadDistance;    // where the next bead goes

  for (let i = 1; i < points.length; i++) {
    const A = points[i - 1];
    const B = points[i];
    const segLength = Math.hypot(B.x - A.x, B.y - A.y);

    if (segLength === 0) continue;  // Safety check 2: pen didn't move, skip
    if (A.id !== B.id) continue;    // pen was lifted between A and B: no beads in the gap

    while (nextBead <= walked + segLength) {
      const t = (nextBead - walked) / segLength;
      beads.push({
        x: A.x + t * (B.x - A.x),
        y: A.y + t * (B.y - A.y),
      });
      nextBead += beadDistance;
    }

    walked += segLength;
  }

  // Rounding errors can leave us one bead short; finish with the last point.
  while (beads.length < n) {
    const last = points[points.length - 1];
    beads.push({ x: last.x, y: last.y });
  }

  return beads;
}

function translateToOrigin(points) {
  let totalX = 0;
  let totalY = 0;
  for(let i = 0; i < points.length; i++) {
    //find center
    totalX += points[i].x;
    totalY += points[i].y;
  }

  let centerX = totalX / points.length;
  let centerY = totalY / points.length;
  const translatedPoints = [];
  for (let j = 0; j < points.length; j++) {
    const translatedX = points[j].x - centerX;
    const translatedY = points[j].y - centerY;
    translatedPoints.push({x: translatedX, y: translatedY});
  }
  
  return translatedPoints;
  
}

function scaleToUnit(points) {
  // Find the bounding box: smallest and largest x and y
  let minX = Infinity, maxX = -Infinity;
  let minY = Infinity, maxY = -Infinity;
  for (let i = 0; i < points.length; i++) {
    minX = Math.min(minX, points[i].x);
    maxX = Math.max(maxX, points[i].x);
    minY = Math.min(minY, points[i].y);
    maxY = Math.max(maxY, points[i].y);
  }

  const width = maxX - minX;
  const height = maxY - minY;
  const size = Math.max(width, height);   // the bigger side

  if (size === 0) return points;          // a single dot: nothing to scale

  const scale = 1 / size;
  const scaled = [];
  for (let i = 0; i < points.length; i++) {
    scaled.push({ x: points[i].x * scale, y: points[i].y * scale });
  }
  return scaled;
}

// All three steps together: what we'll call on every drawing and template
function normalize(points) {
  return scaleToUnit(translateToOrigin(resample(points, NUM_POINTS)));
}



// ---------- Point-cloud matching (the $P recognizer) ----------
// Stroke order and direction are ignored: each shape is just a cloud of 32 dots.
// Each dot in cloud a claims the closest dot in cloud b that nobody has claimed yet.
function greedyMatch(a, b, start) {
  const n = a.length;
  const claimed = new Array(n).fill(false);
  let total = 0;

  for (let k = 0; k < n; k++) {
    const i = (start + k) % n;            // walk around a, beginning at 'start'
    let closest = -1;
    let closestDist = Infinity;
    for (let j = 0; j < n; j++) {
      if (claimed[j]) continue;           // each template dot can only be used once
      const d = Math.hypot(a[i].x - b[j].x, a[i].y - b[j].y);
      if (d < closestDist) { closestDist = d; closest = j; }
    }
    claimed[closest] = true;
    const weight = 1 - k / n;             // early picks had the most choice, so they count most
    total += weight * closestDist;
  }
  return total;
}

// Greedy matching depends a little on which dot goes first, so try several
// starting dots, in both directions (a->b and b->a), and keep the best score.
function cloudDistance(a, b) {
  const n = a.length;
  const step = Math.floor(Math.sqrt(n));  // about 6 starting points for 32 dots
  let best = Infinity;
  for (let start = 0; start < n; start += step) {
    best = Math.min(best, greedyMatch(a, b, start), greedyMatch(b, a, start));
  }
  return best;
}

// Compare a symbol (a list of strokes) against every template and return the best matches.
// Returns a list like [{ label: "2", score: 1.4 }, { label: "3", score: 3.9 }, ...],
// sorted best first. A lower score means a closer match.
function recognize(strokes, templates) {
  if (templates.length === 0) return [];

  const drawn = normalize(flatten(strokes));       // your drawing (all its strokes), reduced to its shape
  const bestPerLabel = {};                         // label → its closest template's score

  for (let i = 0; i < templates.length; i++) {
    const template = templates[i];
    const shape = template.shape;  // precomputed point cloud
    const score = cloudDistance(drawn, shape);

    // Several templates share a label (your three "2"s). Keep only the best one.
    if (bestPerLabel[template.label] === undefined || score < bestPerLabel[template.label]) {
      bestPerLabel[template.label] = score;
    }
  }

  // Turn { "2": 1.4, "3": 3.9 } into a list and sort it, smallest score first
  const results = [];
  for (const label in bestPerLabel) {
    results.push({ label: label, score: bestPerLabel[label] });
  }
  results.sort((a, b) => a.score - b.score);
  return results;
}
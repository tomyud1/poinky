/* Poinky lessons: a paper window where a yellow pen draws an explanation step by step,
   in time with the narration. The pen can also leave the paper to mark things on the screen.

   SB.lessonBegin({x, y, w, h0}, title)   open a fresh paper at screen position (points)
   SB.lessonStep({ops:[…]}, k)            queue drawing operations (k: screen points per screenshot pixel)
   SB.lessonStop()                        stop drawing (you interrupted); what's drawn stays

   Paper coordinates: 800 units wide, y grows downward. The paper grows and shrinks with what's on it,
   and moves up the screen when it needs room (never over `avoid`, what's being explained). */
(function () {
  const X = window.SBX, SB = window.SB, NS = 'http://www.w3.org/2000/svg';
  const UNITS = 800;
  const THEME = {
    blue: ['#4a7bd8', '#dfe8fb'], red: ['#df7b7b', '#fbe3e3'], green: ['#58b07a', '#e2f4e8'],
    yellow: ['#d9ad3c', '#fdf2d3'], purple: ['#9a7ddf', '#ece6fb'], orange: ['#e8914a', '#fde9da'],
    gray: ['#9aa0a8', '#eceef1'], teal: ['#3aa89a', '#dff3f0'], pink: ['#d36aa8', '#fbe6f2'],
  };
  const INK = '#3b3b3b', MUTED = '#808080', PEN_INK = '#d4a72c';
  const FONT = '"Noteworthy", "Chalkboard SE", "Marker Felt", ui-rounded, system-ui';

  const style = document.createElement('style');
  style.textContent = `
    #pen{position:absolute;left:0;top:0;width:26px;height:26px;pointer-events:none;opacity:0;transition:opacity .4s;z-index:50;
      filter:drop-shadow(0 1px 2px rgba(0,0,0,.35))}
    .card.lpaper{border-radius:14px;overflow:hidden;background-color:#fbf8f0;
      background-image:linear-gradient(rgba(0,0,0,.035) 1px,transparent 1px),linear-gradient(90deg,rgba(0,0,0,.035) 1px,transparent 1px);
      background-size:22px 22px;box-shadow:0 22px 60px rgba(0,0,0,.35),0 0 0 1px rgba(0,0,0,.08);animation:lp-in .5s cubic-bezier(.2,.9,.3,1.1)}
    .lpaper .lsvg{display:block;width:100%;overflow:hidden}
    .lpaper .lsvg text{font-family:${FONT}}
    @keyframes lp-in{from{opacity:0;transform:translateY(18px) scale(.97)}to{opacity:1;transform:none}}`;
  document.head.appendChild(style);

  const pen = document.createElement('div');
  pen.id = 'pen';
  pen.innerHTML = '<svg width="26" height="26" viewBox="0 0 26 26"><path d="M3 3 L21 11 L12.5 13 L10 21.5 Z" fill="#f3c34f" stroke="#b58a1c" stroke-width="1.3" stroke-linejoin="round"/></svg>';
  document.body.appendChild(pen);

  let paper = null, svg = null, defs = null, frame = null, H = 260, scale = 1;
  let queue = [], running = false, token = 0, penPos = null, penHide = null, uid = 0, screenMarks = 0;
  // Draw faster when steps are waiting, so the drawing catches up with the voice.
  let pace = 1;
  const items = {};
  // Areas already used on the paper, so new shapes and text don't land on top of old ones.
  let used = [];
  const overlap = (a, b) => Math.max(0, Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x)) * Math.max(0, Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y));
  /** How far down to move rectangle r so it doesn't collide with what's drawn. */
  function freeShift(r) {
    let dy = 0;
    for (let k = 0; k < 8; k++) {
      const c = { x: r.x, y: r.y + dy, w: r.w, h: r.h };
      const hit = used.find(b => overlap(c, b) > 0.2 * Math.min(c.w * c.h, b.w * b.h));
      if (!hit) return dy;
      dy = hit.y + hit.h + 8 - r.y;
    }
    return dy;
  }
  const claim = (r, id) => used.push({ ...r, id });

  // ---------- small helpers ----------
  function el(tag, attrs, parent) {
    const e = document.createElementNS(NS, tag);
    for (const k in attrs) if (attrs[k] !== undefined) e.setAttribute(k, attrs[k]);
    parent.appendChild(e);
    return e;
  }
  const theme = c => THEME[c] || null;
  const textColor = c => c === 'gray' || c === 'muted' ? MUTED : (theme(c) ? theme(c)[0] : (c || INK));
  const ease = u => u < .5 ? 2 * u * u : 1 - Math.pow(-2 * u + 2, 2) / 2;
  const jit = a => (Math.random() * 2 - 1) * a;

  function tween(dur, fn) {
    return new Promise(res => {
      const my = token, t0 = performance.now();
      function f(now) {
        if (my !== token) return res(false);
        const u = Math.min(1, (now - t0) / (dur * 1000));
        fn(u);
        if (u < 1) requestAnimationFrame(f); else res(true);
      }
      requestAnimationFrame(f);
    });
  }
  const wait = s => tween(s, () => {});

  function setPen(x, y) {
    penPos = [x, y];
    pen.style.transform = `translate(${x - 3}px, ${y - 3}px)`;
    pen.style.opacity = 1;
    clearTimeout(penHide);
  }
  async function penTo(x, y) {
    if (!penPos) { setPen(x, y); return; }
    const [x0, y0] = penPos, d = Math.hypot(x - x0, y - y0);
    if (d < 2) return;
    await tween(Math.min(.45, .1 + d / 2600) / pace, u => { const e = ease(u); setPen(x0 + (x - x0) * e, y0 + (y - y0) * e); });
  }
  // Paper units → screen points.
  function onScreen(x, y) {
    const p = svg.createSVGPoint(); p.x = x; p.y = y;
    const q = p.matrixTransform(svg.getScreenCTM());
    return [q.x, q.y];
  }
  const same = (x, y) => [x, y];

  /** Reveal a path while the pen tip follows it. speed in path units per second. */
  async function drawPath(path, toScreen, speed = 650) {
    const L = path.getTotalLength();
    if (!(L > 0)) return;
    path.style.strokeDasharray = L;
    path.style.strokeDashoffset = L;
    const p0 = path.getPointAtLength(0);
    await penTo(...toScreen(p0.x, p0.y));
    const ok = await tween(Math.max(.12, L / speed) / pace, u => {
      path.style.strokeDashoffset = L * (1 - u);
      const p = path.getPointAtLength(L * u);
      setPen(...toScreen(p.x, p.y));
    });
    if (ok) { path.style.strokeDasharray = ''; path.style.strokeDashoffset = ''; }
  }

  // ---------- paper ----------
  // H = how tall the drawing is (paper units). The paper shows all of it when there's room (moving
  // up the screen if needed); when there isn't, it zooms out a little, then scrolls so the pen stays in view.
  const MIN_ZOOM = .72, BAR = 32, EDGE = 24;
  let view = { h: 0, y: 0, vh: 0 };   // shown: svg height (points), viewBox top and height (units)
  let top = 0;                        // the paper's top on screen (points)
  // The band of the screen the paper may use: not over what's being explained (`avoid`).
  function band() {
    let lo = 44, hi = innerHeight - EDGE;
    const a = frame.avoid;
    if (a && a.x < frame.x + frame.w && a.x + a.w > frame.x) {
      if (a.y + a.h <= frame.y + 8) lo = Math.max(lo, a.y + a.h + 12);    // it's above the paper
      else if (a.y >= frame.y) hi = Math.min(hi, a.y - 12);               // it's below
    }
    lo = Math.min(lo, frame.y); hi = Math.max(hi, frame.y + 200);
    return { lo, hi };
  }
  function room() { const b = band(); return Math.max(200, b.hi - b.lo - BAR); }   // points for the drawing
  function setHeight(h) {
    H = h;
    const cap = room() / scale;          // units that fit at full size
    let target;
    if (H <= cap) target = { h: H * scale, y: 0, vh: H };
    else if (H * MIN_ZOOM <= cap) target = { h: room(), y: 0, vh: H };                 // zoom out to fit everything
    else { const vh = cap / MIN_ZOOM; target = { h: room(), y: H - vh, vh }; }         // scroll: keep the newest part visible
    animateView(target);
    // Where it sits: where it was placed, moved up just enough when it gets tall (unless you moved it).
    if (paper && !paper.dataset.moved) {
      const b = band();
      const t = Math.max(b.lo, Math.min(frame.y, b.hi - BAR - target.h));
      if (Math.abs(t - top) > 1) { top = t; paper.style.transition = 'top .38s cubic-bezier(.3,.9,.3,1)'; paper.style.top = t + 'px'; }
    }
    label();
  }
  function applyView(v) {
    svg.style.height = v.h + 'px';
    svg.setAttribute('viewBox', `0 ${v.y.toFixed(1)} ${UNITS} ${v.vh.toFixed(1)}`);
  }
  function animateView(target) {
    const from = { ...view }, t0 = performance.now();
    if (!from.vh) { view = target; applyView(view); return; }
    const step = now => {
      const u = Math.min(1, (now - t0) / 380), e = ease(u);
      view = { h: from.h + (target.h - from.h) * e, y: from.y + (target.y - from.y) * e, vh: from.vh + (target.vh - from.vh) * e };
      applyView(view);
      if (u < 1) requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  }
  // How far down the drawing goes; the teacher reads it for follow-ups that continue on the paper.
  let contentBottom = 0;
  function label() {
    if (!paper) return;
    paper.dataset.label = `${paper.dataset.title || ''} (paper used down to y≈${Math.round(contentBottom)}${contentBottom ? '' : ', empty'})`;
    X.report();
  }
  function grow(bottom) {
    if (bottom > contentBottom + 1) { contentBottom = bottom; if (bottom + 30 <= H) label(); }
    if (bottom + 30 > H) setHeight(bottom + 30);
  }
  /** After erasing: the paper shrinks to what's left on it. */
  function fit() {
    let bottom = 0;
    for (const id in items) { try { const b = items[id].getBBox(); if (b.height || b.width) bottom = Math.max(bottom, b.y + b.height); } catch (e) {} }
    for (const u of used) bottom = Math.max(bottom, u.y + u.h);
    const h = Math.max(frame.h0 || 240, bottom + 30);
    if (h < H - 1) setHeight(h);
    return bottom;
  }
  // After the paper is cleared, the next drawing starts at the top even if its coordinates
  // continue lower down (everything after it moves up by the same amount).
  let toTop = false, yShift = 0;
  function opTop(o) {
    const ys = [];
    if (typeof o.y === 'number') ys.push(o.op === 'text' ? o.y - (o.size || 22) : (o.op === 'dot' || o.op === 'circle' ? o.y - (o.r || 14) : o.y));
    if (Array.isArray(o.from)) ys.push(o.from[1]);
    if (Array.isArray(o.to)) ys.push(o.to[1]);
    if (Array.isArray(o.points)) o.points.forEach(p => ys.push(p[1]));
    return ys.length ? Math.min(...ys) : null;
  }
  function shifted(o, dy) {
    if (!dy) return o;
    const c = { ...o };
    if (typeof c.y === 'number') c.y += dy;
    if (Array.isArray(c.from)) c.from = [c.from[0], c.from[1] + dy];
    if (Array.isArray(c.to)) c.to = [c.to[0], c.to[1] + dy];
    if (Array.isArray(c.points)) c.points = c.points.map(p => [p[0], p[1] + dy]);
    return c;
  }

  function newPaper(f, title) {
    frame = f;
    scale = f.w / UNITS;
    const c = document.createElement('div');
    c.className = 'card lpaper';
    c.dataset.id = 'lesson'; c.dataset.type = 'lesson'; c.dataset.label = title || ''; c.dataset.title = title || '';
    Object.assign(c.style, { left: f.x + 'px', top: f.y + 'px', width: f.w + 'px' });
    top = f.y;
    toTop = false; yShift = 0; contentBottom = 0;
    c.innerHTML = '<div class="bar"><span></span><button class="x" title="Close">✕</button></div>';
    c.querySelector('.bar span').textContent = title || '';
    svg = el('svg', { class: 'lsvg', preserveAspectRatio: 'xMidYMin meet' }, c);
    view = { h: 0, y: 0, vh: 0 };
    defs = el('defs', {}, svg);
    c.querySelector('.x').addEventListener('click', () => { SB.lessonStop(); X.removeCard(c); });
    X.dragBy(c.querySelector('.bar'), c);
    // Once you drag it somewhere, it stays there (it still grows and shrinks).
    c.querySelector('.bar').addEventListener('mousedown', () => { c.dataset.moved = '1'; c.style.transition = ''; });
    paper = c;
    setHeight(f.h0 || 240);
    X.cards.appendChild(c);
    for (const k in items) delete items[k];
    used = [];
    paperSound();
    X.report();
  }
  function retire(c) {
    if (!c) return;
    c.classList.add('leaving');
    setTimeout(() => { c.remove(); X.report(); }, 300);
  }

  // A soft, quiet paper rustle (made in code, no sound file).
  let actx = null;
  function paperSound() {
    try {
      actx = actx || new AudioContext();
      const dur = .42, n = Math.floor(actx.sampleRate * dur), buf = actx.createBuffer(1, n, actx.sampleRate), d = buf.getChannelData(0);
      for (let i = 0; i < n; i++) {
        const t = i / n;
        d[i] = (Math.random() * 2 - 1) * Math.pow(Math.sin(Math.PI * t), 2) * (.55 + .45 * Math.abs(Math.sin(t * 23)));
      }
      const src = actx.createBufferSource(); src.buffer = buf;
      const f = actx.createBiquadFilter(); f.type = 'bandpass'; f.frequency.value = 2600; f.Q.value = .6;
      const g = actx.createGain(); g.gain.value = .05;
      src.connect(f).connect(g).connect(actx.destination);
      src.start();
    } catch (e) {}
  }

  // ---------- drawing operations ----------
  function group(o, parent) {
    const g = el('g', { 'data-id': o.id }, parent || svg);
    if (o.id) items[o.id] = g;
    return g;
  }

  async function writeText(g, o) {
    const size = o.size || 22;
    const t = el('text', {
      x: o.x, y: o.y, 'font-size': size, fill: textColor(o.color),
      'text-anchor': o.align === 'center' ? 'middle' : (o.align === 'right' ? 'end' : 'start'),
      'font-weight': o.bold ? 700 : 400,
    }, g);
    t.textContent = o.text || '';
    let bb = t.getBBox();
    if (o.free !== false) {
      const dy = freeShift({ x: bb.x, y: bb.y, w: bb.width, h: bb.height });
      if (dy) { o = { ...o, y: o.y + dy }; t.setAttribute('y', o.y); bb = t.getBBox(); }
      claim({ x: bb.x, y: bb.y, w: bb.width, h: bb.height }, o.id);
    }
    grow(bb.y + bb.height);
    const id = 'clip' + (++uid);
    const cp = el('clipPath', { id }, defs);
    const r = el('rect', { x: bb.x - 3, y: bb.y - 6, width: 0, height: bb.height + 12 }, cp);
    t.setAttribute('clip-path', `url(#${id})`);
    const baseY = o.y - size * .3;
    await penTo(...onScreen(bb.x, baseY));
    const ok = await tween(Math.max(.2, (o.text || '').length / 26) / pace, u => {
      r.setAttribute('width', (bb.width + 6) * u);
      setPen(...onScreen(bb.x + bb.width * u, baseY + Math.sin(u * 50) * size * .1));
    });
    if (ok) { t.removeAttribute('clip-path'); cp.remove(); } else { r.setAttribute('width', bb.width + 6); }
  }

  function roundRect(x, y, w, h, r) {
    const j = () => jit(1.2);
    return `M${x + r + j()},${y + j()} L${x + w - r + j()},${y + j()} Q${x + w},${y} ${x + w + j()},${y + r} ` +
      `L${x + w + j()},${y + h - r} Q${x + w},${y + h} ${x + w - r},${y + h + j()} L${x + r + j()},${y + h + j()} ` +
      `Q${x},${y + h} ${x + j()},${y + h - r} L${x + j()},${y + r} Q${x},${y} ${x + r + 1},${y}`;
  }

  async function box(o) {
    const g = group(o);
    const [stroke, fill] = theme(o.color) || THEME.gray;
    const { x, w, h } = o;
    const y = o.y + freeShift({ x, y: o.y, w, h });
    claim({ x, y, w, h }, o.id);
    grow(y + h);
    const bg = el('rect', { x, y, width: w, height: h, rx: 8, fill, opacity: 0 }, g);
    const p = el('path', { d: roundRect(x, y, w, h, 8), fill: 'none', stroke, 'stroke-width': 2.4, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' }, g);
    await drawPath(p, onScreen, 1400);
    bg.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 250, fill: 'forwards' });
    if (o.text) await writeText(g, { x: x + w / 2, y: y + h / 2 + (o.size || 26) * .35, text: o.text, size: o.size || 26, align: 'center', color: o.textColor, free: false });
  }

  async function arrow(o, parent, toScreen, colorDefault) {
    const g = group(o, parent);
    const [x1, y1] = o.from, [x2, y2] = o.to;
    const bend = o.curve || 0, len = Math.hypot(x2 - x1, y2 - y1) || 1;
    const cx = (x1 + x2) / 2 - (y2 - y1) / len * bend, cy = (y1 + y2) / 2 + (x2 - x1) / len * bend;
    const col = theme(o.color) ? theme(o.color)[0] : (o.color || colorDefault || INK);
    const wdt = o.width || 2.2;
    if (parent === svg || !parent) grow(Math.max(y1, y2, cy) + 10);
    const shaft = el('path', { d: `M${x1},${y1} Q${cx},${cy} ${x2},${y2}`, fill: 'none', stroke: col, 'stroke-width': wdt, 'stroke-linecap': 'round' }, g);
    await drawPath(shaft, toScreen);
    const a = Math.atan2(y2 - cy, x2 - cx), s = 13;
    const head = el('path', {
      d: `M${x2 - s * Math.cos(a - .45)},${y2 - s * Math.sin(a - .45)} L${x2},${y2} L${x2 - s * Math.cos(a + .45)},${y2 - s * Math.sin(a + .45)}`,
      fill: 'none', stroke: col, 'stroke-width': wdt, 'stroke-linecap': 'round', 'stroke-linejoin': 'round',
    }, g);
    await drawPath(head, toScreen, 900);
    if (o.label && (parent === svg || !parent)) await writeText(g, { x: cx, y: cy - 12, text: o.label, size: 18, align: 'center', color: 'gray', free: false });
  }

  async function line(o) {
    const g = group(o);
    const pts = o.points || [];
    if (pts.length < 2) return;
    grow(Math.max(...pts.map(p => p[1])) + 10);
    const col = theme(o.color) ? theme(o.color)[0] : (o.color || INK);
    const p = el('path', {
      d: pts.map((q, i) => (i ? 'L' : 'M') + q[0] + ',' + q[1]).join(' '), fill: 'none', stroke: col,
      'stroke-width': o.width || 2.2, 'stroke-linecap': 'round', 'stroke-linejoin': 'round',
      'stroke-dasharray': o.dashed ? '6 7' : undefined,
    }, g);
    if (o.dashed) { p.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 300, fill: 'forwards' }); await penTo(...onScreen(...pts[pts.length - 1])); }
    else await drawPath(p, onScreen);
  }

  function circlePath(cx, cy, r) {
    const a0 = Math.random() * Math.PI * 2;
    let d = '';
    for (let i = 0; i <= 40; i++) {
      const a = a0 + Math.PI * 2 * 1.04 * i / 40, w = 1 + .02 * Math.sin(a * 2);
      d += (i ? 'L' : 'M') + (cx + Math.cos(a) * r * w).toFixed(1) + ',' + (cy + Math.sin(a) * r * w).toFixed(1);
    }
    return d;
  }

  async function dot(o) {
    const g = group(o);
    const [stroke, fill] = theme(o.color) || THEME.purple;
    const r = o.r || 14;
    o = { ...o, y: o.y + freeShift({ x: o.x - r, y: o.y - r, w: 2 * r, h: 2 * r }) };
    claim({ x: o.x - r, y: o.y - r, w: 2 * r, h: 2 * r }, o.id);
    grow(o.y + r);
    const bg = el('circle', { cx: o.x, cy: o.y, r, fill: o.fill === false ? 'none' : fill, opacity: 0 }, g);
    const p = el('path', { d: circlePath(o.x, o.y, r), fill: 'none', stroke, 'stroke-width': 2.4, 'stroke-linecap': 'round' }, g);
    await drawPath(p, onScreen, 700);
    bg.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 200, fill: 'forwards' });
    if (o.text) await writeText(g, { x: o.x, y: o.y + 7, text: o.text, size: 18, align: 'center', free: false });
  }

  async function check(o) {
    const g = group(o);
    grow(o.y + 14);
    const p = el('path', { d: `M${o.x - 10},${o.y} L${o.x - 2},${o.y + 9} L${o.x + 13},${o.y - 12}`, fill: 'none', stroke: theme(o.color || 'yellow')[0], 'stroke-width': 3, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' }, g);
    await drawPath(p, onScreen, 500);
  }

  async function number(o) {
    const g = group(o);
    grow(o.y + 16);
    const p = el('path', { d: circlePath(o.x, o.y, 14), fill: 'none', stroke: '#c9a227', 'stroke-width': 2, 'stroke-linecap': 'round' }, g);
    el('circle', { cx: o.x, cy: o.y, r: 14, fill: '#fff6d8' }, g).style.opacity = 0;
    await drawPath(p, onScreen, 700);
    await writeText(g, { x: o.x, y: o.y + 6, text: String(o.n ?? ''), size: 17, align: 'center', free: false });
  }

  /** Circle or underline something already on the paper. */
  async function mark(o) {
    const target = items[o.target];
    if (!target) return;
    const bb = target.getBBox();
    const g = group(o);
    let d;
    if (o.style === 'underline') d = `M${bb.x - 4},${bb.y + bb.height + 6} Q${bb.x + bb.width / 2},${bb.y + bb.height + 8} ${bb.x + bb.width + 4},${bb.y + bb.height + 5}`;
    else {
      const cx = bb.x + bb.width / 2, cy = bb.y + bb.height / 2, rx = bb.width / 2 + 14, ry = bb.height / 2 + 12;
      const a0 = Math.random() * 6.28; d = '';
      for (let i = 0; i <= 50; i++) { const a = a0 + Math.PI * 2 * 1.06 * i / 50; d += (i ? 'L' : 'M') + (cx + Math.cos(a) * rx).toFixed(1) + ',' + (cy + Math.sin(a) * ry).toFixed(1); }
    }
    const p = el('path', { d, fill: 'none', stroke: PEN_INK, 'stroke-width': 3, 'stroke-linecap': 'round', opacity: .9 }, g);
    await drawPath(p, onScreen, 800);
  }

  /** The pen leaves the paper to mark the user's screen (coordinates in screenshot pixels × k). */
  async function screenMark(o, k) {
    const s = v => (+v || 0) * k;
    const root = document.getElementById('draw');
    const g = el('g', { 'data-id': o.id || ('pen' + (++screenMarks)), 'data-type': o.type || 'circle', 'data-label': o.label || '' }, root);
    const stroke = { fill: 'none', stroke: PEN_INK, 'stroke-width': 3.5, 'stroke-linecap': 'round', 'stroke-linejoin': 'round', opacity: .95 };
    let d;
    switch (o.type) {
      case 'underline': { const x = s(o.x), y = s(o.y), w = s(o.w); d = `M${x},${y} Q${x + w / 2},${y + 1} ${x + w},${y}`; break; }
      case 'box': { const x = s(o.x), y = s(o.y), w = s(o.w), h = s(o.h); d = roundRect(x - 4, y - 4, w + 8, h + 8, 6); break; }
      case 'arrow':
        await arrow({ from: [s(o.x1), s(o.y1)], to: [s(o.x2), s(o.y2)], color: PEN_INK, width: 3.5 }, g, same, PEN_INK);
        X.report(); return;
      default: { // circle
        const cx = s(o.x), cy = s(o.y), r = Math.max(s(o.r), 14), a0 = Math.random() * 6.28; d = '';
        for (let i = 0; i <= 60; i++) { const a = a0 + Math.PI * 2 * 1.06 * i / 60, w = 1 + .025 * Math.sin(a * 2 + 1); d += (i ? 'L' : 'M') + (cx + Math.cos(a) * r * 1.15 * w).toFixed(1) + ',' + (cy + Math.sin(a) * r * w).toFixed(1); }
      }
    }
    const p = el('path', { d, ...stroke }, g);
    await drawPath(p, same, 900);
    X.report();
  }

  async function erase(o) {
    const ids = o.all ? Object.keys(items) : (o.ids || []);
    for (const id of ids) {
      const g = items[id];
      if (!g) continue;
      g.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 250, fill: 'forwards' });
      setTimeout(() => g.remove(), 260);
      delete items[id];
      used = used.filter(u => u.id !== id);
    }
    if (o.all) {
      // Also what was drawn without an id.
      [...svg.children].forEach(ch => { if (ch.tagName !== 'defs') { ch.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 250, fill: 'forwards' }); setTimeout(() => ch.remove(), 260); } });
      used = [];
    }
    await wait(.28);
    const left = o.all ? 0 : fit();
    contentBottom = Math.max(0, left);
    if (o.all) setHeight(frame.h0 || 240);
    // The paper is empty again: what comes next goes at the top.
    if (left <= 0 && !Object.keys(items).length) { toTop = true; yShift = 0; }
    label();
  }

  async function doOp(o, k) {
    if (!paper || !paper.isConnected) return;
    if (['text', 'box', 'arrow', 'line', 'dot', 'circle', 'check', 'number'].includes(o.op)) {
      const t = opTop(o);
      if (toTop && t != null) { yShift = t > 80 ? 40 - t : 0; toTop = false; }
      // Drawing that already starts near the top again doesn't need moving up any more.
      if (yShift && t != null && t + yShift < 10) yShift = 0;
      o = shifted(o, yShift);
    }
    switch (o.op) {
      case 'text': return writeText(group(o), o);
      case 'box': return box(o);
      case 'arrow': return arrow(o, svg, onScreen);
      case 'line': return line(o);
      case 'dot': case 'circle': return dot(o);
      case 'check': return check(o);
      case 'number': return number(o);
      case 'mark': return mark(o);
      case 'screen': return screenMark(o, k);
      case 'erase': return erase(o);
      case 'clear': return erase({ all: true });
      case 'wait': return wait(Math.min(3, o.s || .4));
      case 'newpage': {
        const f = { ...frame, h0: 240 }, old = paper;
        newPaper(f, o.title || (old && old.dataset.label) || '');
        retire(old);
        return wait(.35);
      }
      case 'close': { retire(paper); paper = null; return; }
    }
  }

  async function run() {
    if (running) return;
    running = true;
    const my = token;
    while (queue.length && my === token) {
      const { ops, k } = queue.shift();
      pace = 1 + .7 * queue.length;
      for (const o of ops) {
        if (my !== token) break;
        try { await doOp(o, k); } catch (e) {}
      }
    }
    if (my === token) {
      running = false;
      penHide = setTimeout(() => { pen.style.opacity = 0; }, 2500);
      X.report();
    }
  }

  SB.lessonBegin = (f, title, continuing) => {
    token++;
    queue = [];
    running = false;
    // A follow-up keeps drawing below what's on the current paper.
    if (continuing && paper && paper.isConnected) { X.report(); return; }
    const old = paper && paper.isConnected ? paper : null;
    newPaper(f, title);
    retire(old);
  };
  SB.lessonStep = (spec, k) => {
    if (!paper || !paper.isConnected) return;
    queue.push({ ops: (spec && spec.ops) || [], k: k || 1 });
    run();
  };
  SB.lessonStop = () => {
    token++;
    queue = [];
    running = false;
    pen.style.opacity = 0;
  };
})();

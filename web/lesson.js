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
  const PAPER = '#fbf8f0';
  // Noteworthy's "1" is a bare stroke, the same as "l" and "I": in math and code that reads wrong, so the
  // digit 1 comes from Chalkboard SE (a flagged 1 in a matching hand).
  const FONT = '"PoinkyHand", "Noteworthy", "Chalkboard SE", "Marker Felt", ui-rounded, system-ui';

  const style = document.createElement('style');
  style.textContent = `
    @font-face{font-family:PoinkyHand;src:local("Noteworthy-Light"),local("Noteworthy");font-weight:400}
    @font-face{font-family:PoinkyHand;src:local("Noteworthy-Bold"),local("Noteworthy");font-weight:700}
    @font-face{font-family:PoinkyHand;src:local("ChalkboardSE-Light"),local("Chalkboard SE");font-weight:400;unicode-range:U+0031}
    @font-face{font-family:PoinkyHand;src:local("ChalkboardSE-Regular"),local("Chalkboard SE");font-weight:700;unicode-range:U+0031}
    #pen{position:absolute;left:0;top:0;width:26px;height:26px;pointer-events:none;opacity:0;transition:opacity .4s;z-index:50;
      filter:drop-shadow(0 1px 2px rgba(0,0,0,.35))}
    .card.lpaper{border-radius:14px;overflow:hidden;background-color:#fbf8f0;
      background-image:linear-gradient(rgba(0,0,0,.035) 1px,transparent 1px),linear-gradient(90deg,rgba(0,0,0,.035) 1px,transparent 1px);
      background-size:22px 22px;box-shadow:0 22px 60px rgba(0,0,0,.35),0 0 0 1px rgba(0,0,0,.08);animation:lp-in .5s cubic-bezier(.2,.9,.3,1.1)}
    .lpaper .lsvg{display:block;width:100%;overflow:hidden}
    .lpaper .lsvg text{font-family:${FONT};white-space:pre;paint-order:stroke;stroke:var(--halo,${PAPER});stroke-width:5px;stroke-linejoin:round}
    .lpaper .lsvg text.nohalo{stroke:none}
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
    for (const k in graphs) delete graphs[k];
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

  // ---------- math: a small TeX-like notation drawn in the handwriting ----------
  // x^2, x^{n+1}, a_1, \frac{dy}{dx}, \sqrt{x}, \cdot \times \to \le \pi \Delta …, \text{words}.
  // In math, * is a dot, -> an arrow, <= / >= / != the real signs.
  const SYM = {
    alpha: 'α', beta: 'β', gamma: 'γ', Gamma: 'Γ', delta: 'δ', Delta: 'Δ', epsilon: 'ε', varepsilon: 'ε', zeta: 'ζ', eta: 'η',
    theta: 'θ', Theta: 'Θ', kappa: 'κ', lambda: 'λ', Lambda: 'Λ', mu: 'μ', nu: 'ν', xi: 'ξ', pi: 'π', Pi: 'Π', rho: 'ρ',
    sigma: 'σ', Sigma: 'Σ', tau: 'τ', phi: 'φ', varphi: 'φ', Phi: 'Φ', chi: 'χ', psi: 'ψ', Psi: 'Ψ', omega: 'ω', Omega: 'Ω',
    infty: '∞', cdot: '·', times: '×', div: '÷', pm: '±', mp: '∓', to: '→', rightarrow: '→', Rightarrow: '⇒', implies: '⇒',
    leftarrow: '←', leftrightarrow: '↔', iff: '⇔', le: '≤', leq: '≤', ge: '≥', geq: '≥', ne: '≠', neq: '≠', approx: '≈',
    equiv: '≡', sim: '∼', propto: '∝', int: '∫', sum: 'Σ', prod: 'Π', partial: '∂', nabla: '∇', circ: '∘', degree: '°',
    in: '∈', notin: '∉', subset: '⊂', cup: '∪', cap: '∩', emptyset: '∅', forall: '∀', exists: '∃', neg: '¬', land: '∧', lor: '∨',
    ldots: '…', dots: '…', cdots: '⋯', angle: '∠', perp: '⊥', parallel: '∥', triangle: '△', prime: '′', ',': ' ', ';': ' ', ' ': ' ', quad: '  ',
    sin: 'sin', cos: 'cos', tan: 'tan', ln: 'ln', log: 'log', exp: 'exp', lim: 'lim', max: 'max', min: 'min',
    left: '', right: '', displaystyle: '', '{': '{', '}': '}', '%': '%', '$': '$', '#': '#', '_': '_', '&': '&',
  };
  /** Mathy text: a hint to draw it as math even without "math": true. */
  const looksMath = s => /\\(frac|sqrt|cdot|times|pi|theta|alpha|Delta|int|sum|le|ge|to)\b|\^[{(\d]|_\{/.test(s);
  // Chemical formulas in plain text (H2O, CO2, C6H12O6) get their numbers written small and low.
  const ELEMENTS = new Set('H He Li Be B C N O F Ne Na Mg Al Si P S Cl Ar K Ca Ti Cr Mn Fe Co Ni Cu Zn Br Ag Sn I Au Hg Pb U'.split(' '));
  const NOT_CHEM = new Set(['PS2', 'PS3', 'PS4', 'PS5', 'CS2', 'K2', 'B12', 'F35', 'F16', 'C4', 'U2']);
  function chemParts(word) {
    if (NOT_CHEM.has(word) || !/\d/.test(word) || !/^([A-Z][a-z]?\d*)+$/.test(word)) return null;
    const parts = word.match(/[A-Z][a-z]?\d*/g);
    if (!parts.every(p => ELEMENTS.has(p.replace(/\d+/, '')))) return null;
    if (parts.length < 2 && !['H2', 'O2', 'N2', 'Cl2', 'O3'].includes(word)) return null;
    return word.split(/(\d+)/).filter(Boolean);
  }
  /** Fills a text element, writing chemical formulas with subscripts. */
  function fillText(t, str, size) {
    const words = str.split(/(\b[A-Za-z0-9]+\b)/);
    if (!words.some(w => chemParts(w))) { t.textContent = str; return; }
    let low = false;
    for (const w of words) {
      const parts = chemParts(w);
      for (const p of parts || [w]) {
        const sub = !!parts && /^\d+$/.test(p);
        const span = el('tspan', {}, t);
        if (sub !== low) { span.setAttribute('dy', (sub ? .28 : -.28) * size); low = sub; }
        if (sub) span.setAttribute('font-size', size * .68);
        span.textContent = p;
      }
    }
  }
  /** A JSON "\frac" arrives as a form feed + "rac" (and \t, \b, \n, \r likewise): put the backslash back. */
  const unescapeTex = s => s.replace(/\f/g, '\\f').replace(/\t/g, '\\t').replace(/\x08/g, '\\b').replace(/\r/g, '\\r')
    .replace(/\n(?=[a-zA-Z])/g, '\\n');

  function parseTex(src) {
    let i = 0;
    const s = unescapeTex(src).replace(/->/g, '→').replace(/-/g, '−').replace(/<=/g, '≤').replace(/>=/g, '≥').replace(/!=/g, '≠')
      .replace(/(\S)\s*\*\s*(?=\S)/g, '$1 · ').replace(/'/g, '′');
    function group(stop) {
      const out = [];
      while (i < s.length && s[i] !== stop) {
        const c = s[i];
        if (c === '^' || c === '_') {
          i++;
          const arg = argument();
          let base = out.pop() || { t: 'text', s: '' };
          if (base.t !== 'script') base = { t: 'script', base, sup: null, sub: null };
          base[c === '^' ? 'sup' : 'sub'] = arg;
          out.push(base);
        } else out.push(atom());
      }
      if (stop && s[i] === stop) i++;
      return out;
    }
    function argument() {
      while (s[i] === ' ') i++;
      if (s[i] === '{') { i++; return group('}'); }
      if (s[i] === '\\') return [atom()];
      if (s[i] === '(') {   // calculator style: e^(2x), x^(n+1)
        let depth = 0, j = i;
        for (; j < s.length; j++) { if (s[j] === '(') depth++; else if (s[j] === ')' && --depth === 0) break; }
        const inner = s.slice(i + 1, j); i = Math.min(s.length, j + 1);
        return parseTex(inner);
      }
      // Without braces: a number (x^10, 2^-n), or else one character (H_2O, e^x).
      const m = /^[-+−]?(\d+(\.\d+)?|[^\s\d])/.exec(s.slice(i));
      if (!m) return [];
      i += m[0].length;
      return [{ t: 'text', s: m[0].replace('-', '−') }];
    }
    function atom() {
      const c = s[i];
      if (c === '{') { i++; return { t: 'row', items: group('}') }; }
      if (c === '\\') {
        i++;
        let name = '';
        if (/[a-zA-Z]/.test(s[i] || '')) while (/[a-zA-Z]/.test(s[i] || '')) name += s[i++];
        else name = s[i++] || '';
        if (name === 'frac' || name === 'dfrac' || name === 'tfrac') { const num = argument(), den = argument(); return { t: 'frac', num, den }; }
        if (name === 'sqrt') { let idx = null; if (s[i] === '[') { const e = s.indexOf(']', i); idx = s.slice(i + 1, e); i = e + 1; } return { t: 'sqrt', body: argument(), idx }; }
        if (name === 'text' || name === 'mathrm' || name === 'textbf' || name === 'mathbf' || name === 'operatorname') {
          if (s[i] === '{') { const e = s.indexOf('}', i); const txt = s.slice(i + 1, e < 0 ? s.length : e); i = e < 0 ? s.length : e + 1; return { t: 'text', s: txt }; }
          return { t: 'text', s: '' };
        }
        if (name === 'overline' || name === 'bar' || name === 'vec' || name === 'hat') return { t: 'over', body: argument(), kind: name };
        return { t: 'text', s: name in SYM ? SYM[name] : name };
      }
      // A run of plain characters (a script attaches after it, which looks the same as after its last letter).
      let run = '';
      while (i < s.length && !'^_{}\\'.includes(s[i])) {
        // Stop before the base of a script so "2x^2" raises only past "x" (same place, but keeps sizes right).
        if ((s[i + 1] === '^' || s[i + 1] === '_') && run) break;
        run += s[i++];
      }
      return { t: 'text', s: run };
    }
    return group(null);
  }

  /** Lays out parsed math; returns a box {w, a, d, draw(parent, x, y)} (a/d: height above/below the baseline). */
  function layoutTex(nodes, size, color, measure) {
    function text(str) {
      const w = measure(str, size);
      return { w, a: size * .74, d: size * .24, draw(p, x, y) { const t = el('text', { x, y, 'font-size': size, fill: color }, p); t.textContent = str; } };
    }
    function row(list, sz) { return layoutTex(list, sz, color, measure); }
    const boxes = nodes.map(n => {
      if (n.t === 'text') return text(n.s);
      if (n.t === 'row') return row(n.items, size);
      if (n.t === 'script') {
        const b = layoutTex([n.base], size, color, measure);
        const ss = Math.max(11, size * .66);
        const up = n.sup && row(n.sup, ss), dn = n.sub && row(n.sub, ss);
        const rise = Math.max(size * .4, b.a - ss * .45), drop = Math.max(size * .18, b.d * .6);
        const w = b.w + 1 + Math.max(up ? up.w : 0, dn ? dn.w : 0);
        return {
          w, a: Math.max(b.a, up ? rise + up.a : 0), d: Math.max(b.d, dn ? drop + dn.d : 0),
          draw(p, x, y) { b.draw(p, x, y); if (up) up.draw(p, x + b.w + 1, y - rise); if (dn) dn.draw(p, x + b.w + 1, y + drop); },
        };
      }
      if (n.t === 'frac') {
        const fs = Math.max(13, size * .86), num = row(n.num, fs), den = row(n.den, fs), pad = size * .14;
        const w = Math.max(num.w, den.w) + 2 * pad, axis = size * .3, gap = size * .14;
        return {
          w: w + size * .12, a: axis + gap + num.d + num.a, d: Math.max(0, gap + den.a + den.d - axis),
          draw(p, x, y) {
            num.draw(p, x + (w - num.w) / 2, y - axis - gap - num.d);
            den.draw(p, x + (w - den.w) / 2, y - axis + gap + den.a);
            el('path', { d: `M${x + 1},${y - axis + jit(.6)} Q${x + w / 2},${y - axis + jit(1.2)} ${x + w - 1},${y - axis + jit(.6)}`, fill: 'none', stroke: color, 'stroke-width': Math.max(1.6, size / 14), 'stroke-linecap': 'round' }, p);
          },
        };
      }
      if (n.t === 'sqrt') {
        const b = row(n.body, size), h = size * .1, lead = size * .62;
        const ix = n.idx ? row([{ t: 'text', s: n.idx }], Math.max(10, size * .5)) : null;
        return {
          w: lead + b.w + size * .12, a: b.a + h + 2, d: b.d,
          draw(p, x, y) {
            const top = y - b.a - h, bot = y + b.d;
            el('path', { d: `M${x},${y - size * .28} L${x + size * .14},${y - size * .36} L${x + size * .32},${bot} L${x + lead - size * .06},${top} L${x + lead + b.w + size * .1},${top + jit(.6)}`, fill: 'none', stroke: color, 'stroke-width': Math.max(1.6, size / 15), 'stroke-linecap': 'round', 'stroke-linejoin': 'round' }, p);
            if (ix) ix.draw(p, x, y - size * .45);
            b.draw(p, x + lead, y);
          },
        };
      }
      if (n.t === 'over') {
        const b = row(n.body, size);
        return {
          w: b.w, a: b.a + size * .16, d: b.d,
          draw(p, x, y) {
            b.draw(p, x, y);
            const ty = y - b.a - size * .06;
            el('path', { d: n.kind === 'vec' ? `M${x},${ty} L${x + b.w},${ty} M${x + b.w - 6},${ty - 4} L${x + b.w},${ty} L${x + b.w - 6},${ty + 4}` : `M${x},${ty} L${x + b.w},${ty}`, fill: 'none', stroke: color, 'stroke-width': 1.6, 'stroke-linecap': 'round' }, p);
          },
        };
      }
      return text('');
    });
    const w = boxes.reduce((t, b) => t + b.w, 0);
    return {
      w, a: Math.max(size * .74, ...boxes.map(b => b.a)), d: Math.max(size * .24, ...boxes.map(b => b.d)),
      draw(p, x, y) { let cx = x; for (const b of boxes) { b.draw(p, cx, y); cx += b.w; } },
    };
  }

  let measurer = null;
  function measure(str, size, bold) {
    if (!measurer || !measurer.isConnected) { measurer = el('text', { x: -9999, y: -9999, opacity: 0 }, svg); }
    measurer.setAttribute('font-size', size);
    measurer.setAttribute('font-weight', bold ? 700 : 400);
    measurer.textContent = str;
    return str ? measurer.getComputedTextLength() : 0;
  }

  /** Draws math at baseline (x, y) in group g; returns the group holding it. */
  function drawMath(g, src, x, y, size, color, align, bold) {
    const box = layoutTex(parseTex(String(src)), size, color, (s, z) => measure(s, z, bold));
    const x0 = align === 'center' ? x - box.w / 2 : align === 'right' ? x - box.w : x;
    const m = el('g', { class: 'math', 'font-weight': bold ? 700 : 400 }, g);
    box.draw(m, x0, y);
    return m;
  }

  /** Reveals node (text or a group) left to right while the pen writes along it. */
  async function reveal(node, bb, size, baseY) {
    const id = 'clip' + (++uid);
    const cp = el('clipPath', { id }, defs);
    const r = el('rect', { x: bb.x - 3, y: bb.y - 6, width: 0, height: bb.height + 12 }, cp);
    node.setAttribute('clip-path', `url(#${id})`);
    await penTo(...onScreen(bb.x, baseY));
    const chars = Math.max(1, bb.width / (size * .5));
    const ok = await tween(Math.max(.2, chars / 26) / pace, u => {
      r.setAttribute('width', (bb.width + 6) * u);
      setPen(...onScreen(bb.x + bb.width * u, baseY + Math.sin(u * 50) * size * .1));
    });
    if (ok) { node.removeAttribute('clip-path'); cp.remove(); } else { r.setAttribute('width', bb.width + 6); }
  }

  async function writeText(g, o) {
    const size = o.size || 22;
    const color = textColor(o.color);
    const isMath = o.op === 'math' || o.math === true || (o.math !== false && looksMath(o.text || ''));
    let node;
    if (isMath) node = drawMath(g, o.text || o.tex || '', o.x, o.y, size, color, o.align, o.bold);
    else {
      node = el('text', {
        x: o.x, y: o.y, 'font-size': size, fill: color,
        'text-anchor': o.align === 'center' ? 'middle' : (o.align === 'right' ? 'end' : 'start'),
        'font-weight': o.bold ? 700 : 400,
      }, g);
      node.setAttributeNS('http://www.w3.org/XML/1998/namespace', 'xml:space', 'preserve');
      fillText(node, o.text || '', size);
    }
    if (o.halo) node.style.setProperty('--halo', o.halo);
    let bb = node.getBBox();
    // Too wide for the paper: shrink it to fit (never past the right margin).
    const maxW = UNITS - 24 - (o.align === 'center' ? 0 : Math.max(0, bb.x));
    if (o.fit !== false && bb.width > maxW + 1 && bb.x >= 0) {
      const k = Math.max(.55, maxW / bb.width);
      node.remove();
      return writeText(g, { ...o, size: size * k, fit: false });
    }
    if (o.free !== false) {
      const dy = freeShift({ x: bb.x, y: bb.y, w: bb.width, h: bb.height });
      if (dy) {
        o = { ...o, y: o.y + dy };
        if (isMath) { node.remove(); node = drawMath(g, o.text || o.tex || '', o.x, o.y, size, color, o.align, o.bold); }
        else node.setAttribute('y', o.y);
        bb = node.getBBox();
      }
      claim({ x: bb.x, y: bb.y, w: bb.width, h: bb.height }, o.id);
    }
    grow(bb.y + bb.height);
    await reveal(node, bb, size, o.y - size * .3);
    return bb;
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
    if (o.text) {
      // Long text shrinks to fit inside the box.
      let size = o.size || 26;
      const tw = measure(o.text, size);
      if (!looksMath(o.text) && !o.math && tw > w - 16) size = Math.max(13, size * (w - 16) / tw);
      await writeText(g, { x: x + w / 2, y: y + h / 2 + size * .35, text: o.text, size, align: 'center', color: o.textColor, free: false, halo: fill, math: o.math, fit: false });
    }
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
    if (o.label && (parent === svg || !parent)) await arrowLabel(g, o.label, [x1, y1], [cx, cy], [x2, y2], o.id);
  }

  /** An arrow's label goes beside the middle of the arrow (not on it), on the side with more room. */
  async function arrowLabel(g, label, p0, c, p2, id) {
    const size = 18;
    const mx = .25 * p0[0] + .5 * c[0] + .25 * p2[0], my = .25 * p0[1] + .5 * c[1] + .25 * p2[1];
    let tx = p2[0] - p0[0], ty = p2[1] - p0[1];
    const L = Math.hypot(tx, ty) || 1; tx /= L; ty /= L;
    let nx = -ty, ny = tx;                      // a normal; make it point up (or left for vertical arrows)
    if (ny > 0 || (Math.abs(ny) < .2 && nx > 0)) { nx = -nx; ny = -ny; }
    const w = measure(label, size) + 6, h = size * 1.1;
    const spot = side => {
      // How far out the label's center must be so its box clears the line: half its extent along the normal.
      const reach = Math.abs(nx) * w / 2 + Math.abs(ny) * h / 2 + 6;
      const cx = mx + side * nx * reach, cy = my + side * ny * reach;
      return { x: cx - w / 2, y: cy - h / 2, w, h };
    };
    const cost = r => used.reduce((t, b) => t + overlap(r, b), 0) + (r.x < 4 || r.x + r.w > UNITS - 4 || r.y < 4 ? 1e6 : 0);
    const a = spot(1), b = spot(-1), r = cost(b) < cost(a) * .6 ? b : a;
    claim(r, id);
    await writeText(g, { x: r.x + r.w / 2, y: r.y + r.h / 2 + size * .33, text: label, size, align: 'center', color: 'gray', free: false, fit: false });
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
    if (o.text) await writeText(g, { x: o.x, y: o.y + 7, text: o.text, size: 18, align: 'center', free: false, halo: o.fill === false ? undefined : fill, fit: false });
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

  // ---------- graphs: axes, curves and points ----------
  /** A function of x from text like "x^2 - 2x + 1", "sin(x)", "2^x", "sqrt(x)/2" (no code is run, only this math). */
  function compileFn(src) {
    const s = String(src).replace(/\s+/g, '').replace(/\*\*/g, '^').replace(/·|×/g, '*').replace(/−/g, '-').replace(/^y=|^f\(x\)=/, '');
    let i = 0;
    const F = { sin: Math.sin, cos: Math.cos, tan: Math.tan, exp: Math.exp, ln: Math.log, log: Math.log10, sqrt: Math.sqrt, abs: Math.abs,
      asin: Math.asin, acos: Math.acos, atan: Math.atan, floor: Math.floor, round: Math.round, sign: Math.sign };
    const C = { pi: Math.PI, e: Math.E, 'π': Math.PI };
    function expr() { let f = term(); while (s[i] === '+' || s[i] === '-') { const op = s[i++], a = f, b = term(); f = op === '+' ? x => a(x) + b(x) : x => a(x) - b(x); } return f; }
    function term() {
      let f = unary();
      for (;;) {
        if (s[i] === '*' || s[i] === '/') { const op = s[i++], a = f, b = unary(); f = op === '*' ? x => a(x) * b(x) : x => a(x) / b(x); }
        else if (i < s.length && /[0-9a-zπ.(]/i.test(s[i])) { const a = f, b = power(); f = x => a(x) * b(x); }   // 2x, 3(x+1), x sin(x)
        else return f;
      }
    }
    function unary() { if (s[i] === '-') { i++; const a = unary(); return x => -a(x); } if (s[i] === '+') { i++; return unary(); } return power(); }
    function power() { const a = atom(); if (s[i] === '^') { i++; const b = unary(); return x => Math.pow(a(x), b(x)); } return a; }
    function atom() {
      const c = s[i];
      if (c === '(') { i++; const f = expr(); if (s[i] === ')') i++; return f; }
      if (/[0-9.]/.test(c)) { let n = ''; while (/[0-9.]/.test(s[i] || '')) n += s[i++]; const v = parseFloat(n); return () => v; }
      if (c === 'x' && !/[a-z]/i.test(s[i + 1] || '')) { i++; return x => x; }
      let name = '';
      while (/[a-zπ]/i.test(s[i] || '')) name += s[i++];
      if (F[name.toLowerCase()]) { const fn = F[name.toLowerCase()], a = s[i] === '(' ? atom() : power(); return x => fn(a(x)); }
      if (name.toLowerCase() in C) { const v = C[name.toLowerCase()]; return () => v; }
      if (name === 'x') return x => x;
      // Letters run together ("xe", "pix"): read them one at a time.
      if (name) { i -= name.length - 1; return atomOf(name[0]); }
      throw new Error('bad expression at ' + i);
    }
    const atomOf = ch => ch === 'x' ? (x => x) : ch in C ? (() => C[ch]) : (() => { throw new Error('unknown ' + ch); });
    const f = expr();
    if (i < s.length) throw new Error('bad expression at ' + i);
    return f;
  }

  const graphs = {};
  /** A nice tick step for a range: 1, 2 or 5 × a power of ten, about 4–8 ticks. */
  function niceStep(span) { const raw = span / 5, p = Math.pow(10, Math.floor(Math.log10(raw))), m = raw / p; return (m < 1.5 ? 1 : m < 3.5 ? 2 : m < 7.5 ? 5 : 10) * p; }
  const fmtTick = v => { const r = Math.round(v * 1000) / 1000; return (r < 0 ? '−' : '') + Math.abs(r); };

  async function graph(o) {
    const g = group(o);
    const x = o.x ?? 60, w = Math.min(o.w || 320, UNITS - 20 - x), h = o.h || 220;
    const xr = o.xrange || o.x_range || [-5, 5], yr = o.yrange || o.y_range || [-5, 5];
    const y = o.y + freeShift({ x: x - 30, y: o.y - 14, w: w + 50, h: h + 44 });
    claim({ x: x - 30, y: y - 14, w: w + 50, h: h + 44 }, o.id);
    grow(y + h + 34);
    const X = v => x + (v - xr[0]) / (xr[1] - xr[0]) * w, Y = v => y + h - (v - yr[0]) / (yr[1] - yr[0]) * h;
    graphs[o.id || '_'] = { X, Y, xr, yr, x, y, w, h, g, id: o.id };
    graphs._last = graphs[o.id || '_'];
    const col = MUTED;
    // Axes cross at 0 when 0 is in range, otherwise sit on the edge.
    const ax = Math.max(xr[0], Math.min(xr[1], 0)), ay = Math.max(yr[0], Math.min(yr[1], 0));
    if (o.grid) {
      const sx = niceStep(xr[1] - xr[0]), sy = niceStep(yr[1] - yr[0]);
      let d = '';
      for (let v = Math.ceil(xr[0] / sx) * sx; v <= xr[1] + 1e-9; v += sx) d += `M${X(v)},${y} L${X(v)},${y + h} `;
      for (let v = Math.ceil(yr[0] / sy) * sy; v <= yr[1] + 1e-9; v += sy) d += `M${x},${Y(v)} L${x + w},${Y(v)} `;
      el('path', { d, stroke: 'rgba(0,0,0,.08)', 'stroke-width': 1, fill: 'none' }, g).animate([{ opacity: 0 }, { opacity: 1 }], { duration: 300, fill: 'forwards' });
    }
    const axis = (d) => el('path', { d, fill: 'none', stroke: col, 'stroke-width': 2, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' }, g);
    await drawPath(axis(`M${x - 6},${Y(ay)} L${x + w + 8},${Y(ay) + jit(.8)} M${x + w},${Y(ay) - 5} L${x + w + 8},${Y(ay)} L${x + w},${Y(ay) + 5}`), onScreen, 1600);
    await drawPath(axis(`M${X(ax)},${y + h + 6} L${X(ax) + jit(.8)},${y - 8} M${X(ax) - 5},${y} L${X(ax)},${y - 8} L${X(ax) + 5},${y}`), onScreen, 1600);
    if (o.ticks !== false) {
      const sx = o.xstep || niceStep(xr[1] - xr[0]), sy = o.ystep || niceStep(yr[1] - yr[0]);
      const tg = el('g', {}, g);
      let d = '';
      for (let v = Math.ceil(xr[0] / sx) * sx; v <= xr[1] + 1e-9; v += sx) {
        if (Math.abs(v - ax) < sx / 2 && ax !== xr[0]) continue;
        d += `M${X(v)},${Y(ay) - 4} L${X(v)},${Y(ay) + 4} `;
        const t = el('text', { x: X(v), y: Math.min(y + h + 26, Y(ay) + 21), 'font-size': 14, fill: col, 'text-anchor': 'middle' }, tg); t.textContent = fmtTick(v);
      }
      for (let v = Math.ceil(yr[0] / sy) * sy; v <= yr[1] + 1e-9; v += sy) {
        if (Math.abs(v - ay) < sy / 2 && ay !== yr[0]) continue;
        d += `M${X(ax) - 4},${Y(v)} L${X(ax) + 4},${Y(v)} `;
        const t = el('text', { x: Math.max(x - 8, X(ax) - 9), y: Y(v) + 5, 'font-size': 14, fill: col, 'text-anchor': 'end' }, tg); t.textContent = fmtTick(v);
      }
      el('path', { d, stroke: col, 'stroke-width': 1.6, fill: 'none', 'stroke-linecap': 'round' }, tg);
      tg.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 350, fill: 'forwards' });
    }
    if (o.xlabel) await writeText(g, { x: x + w + 14, y: Y(ay) + 6, text: o.xlabel, size: 20, color: 'gray', free: false, fit: false });
    if (o.ylabel) await writeText(g, { x: X(ax) + 10, y: y - 6, text: o.ylabel, size: 20, color: 'gray', free: false, fit: false });
  }

  /** A curve on a graph: "fn" (a function of x) or "points" (data, joined). */
  async function plot(o) {
    const gr = graphs[o.graph] || graphs._last;
    if (!gr) return;
    const g = group(o, gr.g.parentNode === svg ? svg : svg);
    const col = theme(o.color) ? theme(o.color)[0] : (o.color || THEME.blue[0]);
    let pts = [];
    const from = (o.from ?? gr.xr[0]), to = (o.to ?? gr.xr[1]);
    if (Array.isArray(o.points)) pts = o.points.map(p => [+p[0], +p[1]]);
    else if (o.fn) {
      let f; try { f = compileFn(o.fn); } catch (e) { return; }
      const n = 160;
      for (let k = 0; k <= n; k++) { const xv = from + (to - from) * k / n; let yv; try { yv = f(xv); } catch (e) { yv = NaN; } pts.push([xv, yv]); }
    }
    // Split where the curve leaves the graph (or isn't defined), and clip to its box.
    const span = gr.yr[1] - gr.yr[0], segs = [];
    let cur = [];
    for (const [xv, yv] of pts) {
      if (!isFinite(yv) || yv < gr.yr[0] - span * .02 || yv > gr.yr[1] + span * .02) { if (cur.length > 1) segs.push(cur); cur = []; continue; }
      cur.push([gr.X(xv), gr.Y(yv)]);
    }
    if (cur.length > 1) segs.push(cur);
    gr.pts = (gr.pts || []).concat(...segs);
    for (const seg of segs) {
      const p = el('path', { d: seg.map((q, k) => (k ? 'L' : 'M') + q[0].toFixed(1) + ',' + q[1].toFixed(1)).join(' '), fill: 'none', stroke: col,
        'stroke-width': o.width || 2.8, 'stroke-linecap': 'round', 'stroke-linejoin': 'round', 'stroke-dasharray': o.dashed ? '7 7' : undefined }, g);
      if (o.dashed) { p.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 300, fill: 'forwards' }); await penTo(...onScreen(...seg[seg.length - 1])); }
      else await drawPath(p, onScreen, 700);
    }
    if (o.label && segs.length) {
      // At the end of the curve, nudged inside the paper.
      const last = segs[segs.length - 1], [lx, ly] = last[last.length - 1];
      const size = 20, lw = measure(o.label, size);
      const x = Math.min(lx + 8, UNITS - 16 - lw), y = Math.max(ly + (ly < gr.y + 20 ? 22 : -8), 24);
      await writeText(g, { x, y, text: o.label, size, color: o.color || 'blue', free: false, fit: false, math: o.math });
    }
  }

  /** A dot on a graph at data coordinates, with an optional label. */
  async function point(o) {
    const gr = graphs[o.graph] || graphs._last;
    if (!gr || !Array.isArray(o.at)) return;
    const g = group(o);
    const [stroke] = theme(o.color) || THEME.red;
    const px = gr.X(+o.at[0]), py = gr.Y(+o.at[1]);
    if (o.guides) {
      const d = `M${px},${py} L${px},${gr.Y(Math.max(gr.yr[0], Math.min(gr.yr[1], 0)))} M${px},${py} L${gr.X(Math.max(gr.xr[0], Math.min(gr.xr[1], 0)))},${py}`;
      el('path', { d, stroke: stroke, 'stroke-width': 1.6, 'stroke-dasharray': '5 6', fill: 'none', opacity: .7 }, g);
    }
    const p = el('path', { d: circlePath(px, py, 5), fill: stroke, stroke, 'stroke-width': 2 }, g);
    await drawPath(p, onScreen, 300);
    if (o.label) {
      // Of the four corners around the dot, the one that covers the least of the curves and other labels.
      const size = 18, lw = measure(o.label, size), lh = size;
      const spots = [[px + 10, py - 10], [px - 10 - lw, py - 10], [px + 10, py + 10 + lh * .8], [px - 10 - lw, py + 10 + lh * .8]];
      const cost = ([x, y]) => {
        const r = { x: x - 2, y: y - lh * .8, w: lw + 4, h: lh };
        let c = (gr.pts || []).filter(([qx, qy]) => qx > r.x && qx < r.x + r.w && qy > r.y && qy < r.y + r.h).length * 40;
        c += used.reduce((t, b) => t + (b.id === gr.id ? 0 : overlap(r, b)), 0);
        if (r.x < 4 || r.x + r.w > UNITS - 4) c += 1e6;
        return c;
      };
      const [x, y] = spots.reduce((best, sp) => cost(sp) < cost(best) ? sp : best);
      await writeText(g, { x, y, text: o.label, size, color: o.color || 'red', free: false, fit: false, math: o.math });
      claim({ x, y: y - lh * .8, w: lw, h: lh }, o.id);
    }
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
    if (['text', 'math', 'graph', 'axes', 'box', 'arrow', 'line', 'dot', 'circle', 'check', 'number'].includes(o.op)) {
      const t = opTop(o);
      if (toTop && t != null) { yShift = t > 80 ? 40 - t : 0; toTop = false; }
      // Drawing that already starts near the top again doesn't need moving up any more.
      if (yShift && t != null && t + yShift < 10) yShift = 0;
      o = shifted(o, yShift);
    }
    switch (o.op) {
      case 'text': case 'math': return writeText(group(o), o);
      case 'graph': case 'axes': return graph(o);
      case 'plot': return plot(o);
      case 'point': return point(o);
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
  /** Still drawing (for tests and tools). */
  SB.lessonBusy = () => running || queue.length > 0;
  SB._lessonTest = { compileFn, parseTex, items };
  SB.lessonStop = () => {
    token++;
    queue = [];
    running = false;
    pen.style.opacity = 0;
  };
})();

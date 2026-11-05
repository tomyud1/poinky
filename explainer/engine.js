/* Poinky explainer engine: a tiny motion runtime for code-drawn explainer videos.

   A video is a list of scenes. Each scene is code the model writes:
     Explainer.scene('s2', function draw(g) { ... })
   draw(g) is called every frame and must be a pure function of g.t (seconds since the scene
   started): no state kept between frames, randomness only from g.rand(seed). That makes every
   moment renderable on its own (scrubbing, frame checks, exporting).

   The engine has no pictures. It gives drawing tools (shapes, text, paths that draw on, gradients,
   glow), timing (progress, springs, cues tied to spoken words), camera and a palette. Every object
   on screen is drawn by the scene itself. */
(function () {
  const W = 1280, H = 720;
  const scenes = {};

  const STYLE = {
    bg: '#0a1224', bg2: '#101c38', grid: 'rgba(120,150,220,0.07)',
    ink: '#eef2fa', dim: '#8d9abb', faint: '#4a5878', panel: '#16223f', line: '#2a3a60',
    blue: '#5b9cff', green: '#8fd14f', mint: '#3ddc97', pink: '#ff6fa3', amber: '#ffb648',
    violet: '#9b7bff', teal: '#38c7d8', red: '#ff5d5d', white: '#ffffff',
    font: '-apple-system, "SF Pro Display", "Helvetica Neue", Arial, sans-serif',
    mono: '"SF Mono", ui-monospace, Menlo, monospace',
  };

  const clamp = (x, a = 0, b = 1) => (x < a ? a : x > b ? b : x);
  const EASE = {
    linear: x => x,
    in: x => x * x * x,
    out: x => 1 - Math.pow(1 - x, 3),
    inOut: x => (x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2),
    expo: x => (x >= 1 ? 1 : 1 - Math.pow(2, -10 * x)),
    back: x => { const c = 1.70158; return 1 + (c + 1) * Math.pow(x - 1, 3) + c * Math.pow(x - 1, 2); },
  };

  // Damped spring from 0 to 1 starting at local time t0 (overshoots a little, settles in ~0.6 s).
  function springAt(dt, { bounce = 0.25, speed = 1 } = {}) {
    if (dt <= 0) return 0;
    const z = clamp(1 - bounce, 0.15, 1), w = 11 * speed;
    if (z >= 1) return 1 - Math.exp(-w * dt) * (1 + w * dt);
    const wd = w * Math.sqrt(1 - z * z);
    return 1 - Math.exp(-z * w * dt) * (Math.cos(wd * dt) + (z * w / wd) * Math.sin(wd * dt));
  }

  function hexToRgb(c) {
    if (c.startsWith('rgb')) { const m = c.match(/[\d.]+/g).map(Number); return m.slice(0, 3); }
    let h = c.replace('#', ''); if (h.length === 3) h = h.split('').map(x => x + x).join('');
    const n = parseInt(h, 16); return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }

  function mulberry(seed) {
    let a = (typeof seed === 'string' ? [...seed].reduce((h, ch) => (h * 31 + ch.charCodeAt(0)) | 0, 7) : seed | 0) >>> 0;
    return () => { a |= 0; a = (a + 0x6D2B79F5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
  }

  function pathLength(pts) { let L = 0; for (let i = 1; i < pts.length; i++) L += Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]); return L; }
  function pointAlong(pts, u) {
    if (pts.length < 2) return pts[0] ? [...pts[0], 0] : [0, 0, 0];
    const L = pathLength(pts); let d = clamp(u) * L;
    for (let i = 1; i < pts.length; i++) {
      const a = pts[i - 1], b = pts[i], s = Math.hypot(b[0] - a[0], b[1] - a[1]);
      if (d <= s || i === pts.length - 1) { const k = s ? clamp(d / s) : 0; return [a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k, Math.atan2(b[1] - a[1], b[0] - a[0])]; }
      d -= s;
    }
  }
  // Smooth a polyline into a dense curve (Catmull-Rom), so paths look drawn, not jagged.
  function smoothPts(pts, n = 12) {
    if (pts.length < 3) return pts;
    const out = [];
    for (let i = 0; i < pts.length - 1; i++) {
      const p0 = pts[i - 1] || pts[i], p1 = pts[i], p2 = pts[i + 1], p3 = pts[i + 2] || p2;
      for (let k = 0; k < n; k++) {
        const t = k / n, t2 = t * t, t3 = t2 * t;
        out.push([0, 1].map(j => 0.5 * ((2 * p1[j]) + (-p0[j] + p2[j]) * t + (2 * p0[j] - 5 * p1[j] + 4 * p2[j] - p3[j]) * t2 + (-p0[j] + 3 * p1[j] - 3 * p2[j] + p3[j]) * t3)));
      }
    }
    out.push(pts[pts.length - 1]);
    return out;
  }

  /* Layout checks: while lintSink is set, every text drawn is recorded with its box on screen
     (after camera, scale and the canvas's own scaling), so a check can find cropped, tiny or
     overlapping text without looking at pixels. */
  let lintSink = null, lintBase = null;
  function lintText(ctx, s, x, y, w, o, alpha) {
    const size = o.size || 22, al = o.align || 'left', bl = o.baseline || 'alphabetic';
    const x0 = al === 'center' ? x - w / 2 : al === 'right' ? x - w : x;
    const y0 = bl === 'top' ? y : bl === 'middle' ? y - size * 0.5 : y - size * 0.75;
    const y1 = bl === 'top' ? y + size * 0.8 : bl === 'middle' ? y + size * 0.4 : y + size * 0.05;
    const m = (lintBase ? lintBase.inverse().multiply(ctx.getTransform()) : ctx.getTransform());
    const pts = [[x0, y0], [x0 + w, y0], [x0, y1], [x0 + w, y1]].map(([px, py]) => [m.a * px + m.c * py + m.e, m.b * px + m.d * py + m.f]);
    const xs = pts.map(p => p[0]), ys = pts.map(p => p[1]);
    const scale = Math.hypot(m.a, m.b);
    lintSink.push({ s, x0: Math.min(...xs), x1: Math.max(...xs), y0: Math.min(...ys), y1: Math.max(...ys), px: size * scale, alpha });
  }
  // Problems in one frame's recorded text: cropped, at the edge, too small, overlapping.
  function lintFrame(items) {
    const out = [], vis = items.filter(r => r.alpha > 0.6);
    for (const r of vis) {
      const name = JSON.stringify(r.s.length > 30 ? r.s.slice(0, 30) + '…' : r.s);
      if (r.x0 < -2 || r.y0 < -2 || r.x1 > W + 2 || r.y1 > H + 2) out.push(`${name} is cut off by the frame edge (box ${Math.round(r.x0)},${Math.round(r.y0)} to ${Math.round(r.x1)},${Math.round(r.y1)})`);
      else if (r.x0 < 24 || r.y0 < 20 || r.x1 > W - 24 || r.y1 > H - 20) out.push(`${name} touches the frame edge (box ${Math.round(r.x0)},${Math.round(r.y0)} to ${Math.round(r.x1)},${Math.round(r.y1)}; keep 40 px margin)`);
      if (r.px < 15) out.push(`${name} is only ${r.px.toFixed(0)} px tall on screen (min 16 after scale/camera)`);
    }
    for (let i = 0; i < vis.length; i++) for (let j = i + 1; j < vis.length; j++) {
      const a = vis[i], b = vis[j];
      const ix = Math.min(a.x1, b.x1) - Math.max(a.x0, b.x0), iy = Math.min(a.y1, b.y1) - Math.max(a.y0, b.y0);
      if (ix <= 2 || iy <= 2) continue;
      const small = Math.min((a.x1 - a.x0) * (a.y1 - a.y0), (b.x1 - b.x0) * (b.y1 - b.y0));
      if (ix * iy > 0.25 * small) out.push(`${JSON.stringify(a.s)} overlaps ${JSON.stringify(b.s)}`);
    }
    return out;
  }

  /* The drawing context handed to a scene. */
  function makeG(ctx, scene, t) {
    const S = STYLE;
    const g = {
      ctx, W, H, t, dur: scene.dur, S, style: S, clamp, ease: EASE,
      cue(name) { const c = scene.cues && scene.cues[name]; if (c == null) { (g.missing = g.missing || new Set()).add(name); return 0; } return c; },
      // Progress 0..1 of an animation starting at local time t0 lasting d seconds.
      p(t0, d = 0.6, e = 'out') { const x = clamp((t - t0) / d); return (typeof e === 'function' ? e : EASE[e] || EASE.out)(x); },
      spring(t0, opts) { return springAt(t - t0, opts); },
      // 1 while t is in [t0, t1], fading in and out over f seconds.
      during(t0, t1, f = 0.35) { return Math.min(clamp((t - t0) / f), clamp((t1 - t) / f)); },
      lerp: (a, b, k) => a + (b - a) * k,
      mix(c1, c2, k) { const a = hexToRgb(c1), b = hexToRgb(c2); return `rgb(${a.map((v, i) => Math.round(v + (b[i] - v) * clamp(k))).join(',')})`; },
      alpha(c, a) { const [r, gg, b] = hexToRgb(c); return `rgba(${r},${gg},${b},${a})`; },
      rand(seed) { return mulberry(seed); },
      number(n, { decimals = 0, prefix = '', suffix = '' } = {}) { return prefix + Number(n).toLocaleString('en-US', { minimumFractionDigits: decimals, maximumFractionDigits: decimals }) + suffix; },
      count(from, to, k) { return from + (to - from) * clamp(k); },

      background({ grid = 44, glow = S.blue, vignette = true } = {}) {
        const bg = ctx.createLinearGradient(0, 0, 0, H); bg.addColorStop(0, S.bg2); bg.addColorStop(1, S.bg);
        ctx.fillStyle = bg; ctx.fillRect(0, 0, W, H);
        if (glow) { const r = ctx.createRadialGradient(W * 0.5, H * 0.35, 0, W * 0.5, H * 0.35, W * 0.6); r.addColorStop(0, g.alpha(glow, 0.10)); r.addColorStop(1, g.alpha(glow, 0)); ctx.fillStyle = r; ctx.fillRect(0, 0, W, H); }
        if (grid) { ctx.strokeStyle = S.grid; ctx.lineWidth = 1; ctx.beginPath();
          for (let x = (W / 2) % grid; x < W; x += grid) { ctx.moveTo(x + 0.5, 0); ctx.lineTo(x + 0.5, H); }
          for (let y = (H / 2) % grid; y < H; y += grid) { ctx.moveTo(0, y + 0.5); ctx.lineTo(W, y + 0.5); }
          ctx.stroke(); }
        if (vignette) { const v = ctx.createRadialGradient(W / 2, H / 2, H * 0.3, W / 2, H / 2, W * 0.75); v.addColorStop(0, 'rgba(0,0,0,0)'); v.addColorStop(1, 'rgba(0,0,0,0.45)'); ctx.fillStyle = v; ctx.fillRect(0, 0, W, H); }
      },

      // Run fn with a temporary transform / opacity / glow. o: {x, y, scale, sx, sy, rotate, alpha, glow:[color, blur], origin:[ox,oy], camera:[cx,cy,zoom]}
      with(o, fn) {
        ctx.save();
        if (o.camera) { const [cx, cy, z] = o.camera; ctx.translate(W / 2, H / 2); ctx.scale(z, z); ctx.translate(-cx, -cy); }
        if (o.x || o.y) ctx.translate(o.x || 0, o.y || 0);
        if (o.origin) ctx.translate(o.origin[0], o.origin[1]);
        if (o.rotate) ctx.rotate(o.rotate);
        if (o.scale != null || o.sx != null || o.sy != null) ctx.scale(o.sx ?? o.scale ?? 1, o.sy ?? o.scale ?? 1);
        if (o.origin) ctx.translate(-o.origin[0], -o.origin[1]);
        if (o.alpha != null) ctx.globalAlpha *= clamp(o.alpha);
        if (o.glow) { ctx.shadowColor = o.glow[0]; ctx.shadowBlur = o.glow[1] ?? 18; }
        if (o.clip) { ctx.beginPath(); ctx.rect(...o.clip); ctx.clip(); }
        try { fn(); } finally { ctx.restore(); }
      },

      _paint(o, defFill) {
        const a = o.alpha != null ? clamp(o.alpha) : 1;
        if (a <= 0) return;
        ctx.save(); ctx.globalAlpha *= a;
        if (o.glow) { ctx.shadowColor = Array.isArray(o.glow) ? o.glow[0] : o.glow; ctx.shadowBlur = Array.isArray(o.glow) ? (o.glow[1] ?? 18) : 18; }
        const fill = o.fill === undefined ? defFill : o.fill;
        if (fill) { ctx.fillStyle = fill; ctx.fill(); }
        if (o.stroke) { ctx.shadowBlur = o.glow ? ctx.shadowBlur : 0; ctx.strokeStyle = o.stroke; ctx.lineWidth = o.lw || 1.5; if (o.dash) ctx.setLineDash(o.dash); ctx.stroke(); }
        ctx.restore();
      },
      rect(x, y, w, h, o = {}) {
        if (w <= 0 || h <= 0) return; ctx.beginPath();
        const r = Math.min(o.r || 0, w / 2, h / 2);
        if (r) ctx.roundRect(x, y, w, h, r); else ctx.rect(x, y, w, h);
        g._paint(o, S.panel);
      },
      circle(x, y, r, o = {}) { if (r <= 0) return; ctx.beginPath(); ctx.arc(x, y, r, o.from || 0, o.to ?? Math.PI * 2); if (o.pie) ctx.lineTo(x, y); g._paint(o, S.ink); },
      // Ring arc from angle a0 to a1 (radians, 0 = up, clockwise).
      arc(x, y, r, a0, a1, o = {}) { ctx.beginPath(); ctx.arc(x, y, r, a0 - Math.PI / 2, a1 - Math.PI / 2); g._paint({ fill: null, stroke: S.ink, ...o }, null); },
      poly(pts, o = {}) { if (pts.length < 2) return; ctx.beginPath(); ctx.moveTo(...pts[0]); for (const p of pts.slice(1)) ctx.lineTo(...p); if (o.close !== false) ctx.closePath(); g._paint(o, S.panel); },
      // A stroked path. progress (0..1) draws it on; smooth rounds the corners. Returns the pen's position [x, y, angle].
      path(pts, o = {}) {
        let P = o.smooth ? smoothPts(pts) : pts; if (P.length < 2) return P[0];
        const k = o.progress == null ? 1 : clamp(o.progress); if (k <= 0) return [...P[0], 0];
        const L = pathLength(P), end = pointAlong(P, k);
        ctx.save(); ctx.beginPath(); ctx.moveTo(...P[0]); let d = 0;
        for (let i = 1; i < P.length; i++) { const s = Math.hypot(P[i][0] - P[i - 1][0], P[i][1] - P[i - 1][1]); if (d + s >= k * L) { ctx.lineTo(end[0], end[1]); break; } ctx.lineTo(...P[i]); d += s; }
        if (o.fillBelow != null) { ctx.save(); const f = new Path2D(); f.moveTo(P[0][0], o.fillBelow); let dd = 0; f.lineTo(...P[0]);
          for (let i = 1; i < P.length; i++) { const s = Math.hypot(P[i][0] - P[i - 1][0], P[i][1] - P[i - 1][1]); if (dd + s >= k * L) { f.lineTo(end[0], end[1]); break; } f.lineTo(...P[i]); dd += s; }
          f.lineTo(end[0], o.fillBelow); f.closePath(); ctx.fillStyle = o.fillColor || g.alpha(o.stroke || S.mint, 0.15); ctx.fill(f); ctx.restore(); }
        ctx.globalAlpha *= o.alpha ?? 1; ctx.strokeStyle = o.stroke || S.ink; ctx.lineWidth = o.lw || 2; ctx.lineCap = 'round'; ctx.lineJoin = 'round';
        if (o.dash) ctx.setLineDash(o.dash); if (o.dashOffset) ctx.lineDashOffset = o.dashOffset;
        if (o.glow) { ctx.shadowColor = Array.isArray(o.glow) ? o.glow[0] : o.glow; ctx.shadowBlur = Array.isArray(o.glow) ? (o.glow[1] ?? 14) : 14; }
        ctx.stroke(); ctx.restore();
        return end;
      },
      along(pts, u, smooth) { return pointAlong(smooth ? smoothPts(pts) : pts, u); },
      smooth: smoothPts,
      // Text. o: {size, weight, color, align, baseline, mono, alpha, glow, spacing (letter spacing px), maxWidth}
      text(s, x, y, o = {}) {
        const a = o.alpha != null ? clamp(o.alpha) : 1; if (a <= 0 || s == null) return 0;
        ctx.save(); ctx.globalAlpha *= a;
        ctx.font = `${o.weight || 600} ${o.size || 22}px ${o.mono ? S.mono : S.font}`;
        ctx.textAlign = o.align || 'left'; ctx.textBaseline = o.baseline || 'alphabetic';
        if ('letterSpacing' in ctx) ctx.letterSpacing = (o.spacing || 0) + 'px';
        if (o.glow) { ctx.shadowColor = Array.isArray(o.glow) ? o.glow[0] : o.glow; ctx.shadowBlur = Array.isArray(o.glow) ? (o.glow[1] ?? 16) : 16; }
        ctx.fillStyle = o.color || S.ink; ctx.fillText(String(s), x, y, o.maxWidth);
        const w = Math.min(ctx.measureText(String(s)).width, o.maxWidth || Infinity);
        if (lintSink && String(s).trim()) lintText(ctx, String(s), x, y, w, o, ctx.globalAlpha);
        ctx.restore(); return w;
      },
      measure(s, o = {}) { ctx.save(); ctx.font = `${o.weight || 600} ${o.size || 22}px ${o.mono ? S.mono : S.font}`; if ('letterSpacing' in ctx) ctx.letterSpacing = (o.spacing || 0) + 'px'; const w = ctx.measureText(String(s)).width; ctx.restore(); return w; },
      linear(x0, y0, x1, y1, stops) { const gr = ctx.createLinearGradient(x0, y0, x1, y1); stops.forEach(([k, c]) => gr.addColorStop(k, c)); return gr; },
      radial(x, y, r0, r1, stops) { const gr = ctx.createRadialGradient(x, y, r0, x, y, r1); stops.forEach(([k, c]) => gr.addColorStop(k, c)); return gr; },
      // A soft round light (for glows, lit windows, particles).
      light(x, y, r, color, a = 1) { if (r <= 0 || a <= 0) return; ctx.save(); ctx.globalAlpha *= clamp(a); ctx.fillStyle = g.radial(x, y, 0, r, [[0, color], [0.35, g.alpha(color, 0.35)], [1, g.alpha(color, 0)]]); ctx.fillRect(x - r, y - r, 2 * r, 2 * r); ctx.restore(); },
      // Diagonal hatching inside a rect (for "unknown" / "missing" areas).
      hatch(x, y, w, h, o = {}) { if (w <= 0 || h <= 0) return; ctx.save(); ctx.beginPath(); ctx.roundRect(x, y, w, h, o.r || 0); ctx.clip(); ctx.globalAlpha *= o.alpha ?? 1; ctx.strokeStyle = o.stroke || S.dim; ctx.lineWidth = o.lw || 2; const step = o.step || 9; ctx.beginPath(); for (let i = -h; i < w; i += step) { ctx.moveTo(x + i, y + h); ctx.lineTo(x + i + h, y); } ctx.stroke(); ctx.restore(); },
    };
    return g;
  }

  /* ---- The video: scenes on a timeline, cross-faded. ---- */
  const FADE = 0.45;

  function drawScene(ctx, sc, t, errors) {
    const def = scenes[sc.id]; if (!def) return false;
    lintBase = ctx.getTransform();
    const g = makeG(ctx, sc, t - sc.start);
    try { ctx.save(); def(g); } catch (e) { errors && errors.push(`${sc.id}: ${e.message}`); }
    finally { ctx.restore(); }
    if (g.missing && errors) errors.push(`${sc.id}: unknown cue(s) ${[...g.missing].join(', ')}`);
    return true;
  }

  let off = null;
  // Draw the whole video at time t (seconds) into a 2D context sized W x H (logical).
  function render(ctx, manifest, t, errors) {
    const list = manifest.scenes;
    let i = list.findIndex(s => t < s.end); if (i < 0) i = list.length - 1;
    const cur = list[i];
    ctx.save(); ctx.fillStyle = STYLE.bg; ctx.fillRect(0, 0, W, H); ctx.restore();
    const prev = list[i - 1], intoCur = t - cur.start;
    if (prev && intoCur < FADE && scenes[prev.id] && scenes[cur.id]) {
      drawScene(ctx, prev, t, errors);
      if (!off) { off = document.createElement('canvas'); }
      const sx = ctx.getTransform().a; off.width = W * sx; off.height = H * sx;
      const o = off.getContext('2d'); o.setTransform(sx, 0, 0, sx, 0, 0);
      drawScene(o, cur, t, errors);
      ctx.save(); ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.globalAlpha = EASE.inOut(clamp(intoCur / FADE)); ctx.drawImage(off, 0, 0); ctx.restore();
      return true;
    }
    return drawScene(ctx, cur, t, errors);
  }

  window.Explainer = {
    W, H, STYLE, scenes, render, drawScene,
    // Render the frame at t and return its layout problems (text cropped, tiny, overlapping).
    lint(ctx, manifest, t, errors) { lintSink = []; try { render(ctx, manifest, t, errors); return lintFrame(lintSink); } finally { lintSink = null; } },
    scene(id, fn) { scenes[id] = fn; },
  };
})();

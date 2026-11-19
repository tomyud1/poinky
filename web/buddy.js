// The buddy that lives at your cursor. (The status pill at the notch and the sounds are native.)
// Adds to window.SB: tick, phase, buddyOn. Wraps SB.caption / SB.apply /
// SB.fadeCaptions so captions show up in a bubble next to the buddy, and the buddy flies to
// whatever Claude marks on screen.
(function () {
  const SB = window.SB;
  if (!SB) return;

  const css = `
  #buddy{position:absolute;left:0;top:0;width:29px;height:29px;margin:-5.5px 0 0 -5.5px;pointer-events:none;z-index:50;
    opacity:0;transition:opacity .3s;will-change:transform;transform-origin:5.5px 5.5px}
  #buddy.on{opacity:1}
  #buddy .tri,#buddy .dots,#buddy .ring{position:absolute;inset:0}
  #buddy .tri{transition:transform .35s cubic-bezier(.3,1.6,.5,1),opacity .2s;transform-origin:5.5px 5.5px;overflow:visible}
  #buddy .tri path{fill:#3b82ff;stroke:#3b82ff;stroke-width:4;stroke-linejoin:round;
    filter:drop-shadow(0 0 6px rgba(59,130,255,.75)) drop-shadow(0 2px 3px rgba(0,0,0,.25))}
  #buddy .ring{left:-5.5px;top:-5.5px;width:22px;height:22px;border-radius:50%;border:2px solid rgba(59,130,255,.55);
    opacity:0;transform:scale(.6);transition:opacity .2s}
  #buddy.listening .ring{opacity:1}
  #buddy .dots i{position:absolute;left:5.5px;top:5.5px;width:7px;height:7px;margin:-3.5px;border-radius:50%;background:#3b82ff;
    box-shadow:0 0 6px rgba(59,130,255,.8);opacity:0;transform:translate(0,0) scale(.4);
    transition:transform .45s cubic-bezier(.3,1.7,.5,1),opacity .2s}
  #buddy.thinking .tri{transform:scale(0);opacity:0}
  #buddy.thinking .dots i{opacity:1;animation:sbOrbit 1.1s ease-in-out infinite}
  #buddy.thinking .dots i:nth-child(1){--a:0deg;animation-delay:0s}
  #buddy.thinking .dots i:nth-child(2){--a:120deg;animation-delay:-.37s}
  #buddy.thinking .dots i:nth-child(3){--a:240deg;animation-delay:-.73s}
  @keyframes sbOrbit{
    0%{transform:rotate(var(--a)) translate(9px) scale(.9)}
    50%{transform:rotate(calc(var(--a) + 180deg)) translate(6px) scale(1.15)}
    100%{transform:rotate(calc(var(--a) + 360deg)) translate(9px) scale(.9)}}

  #bubble{position:absolute;left:0;top:0;max-width:340px;padding:7px 12px;border-radius:13px;pointer-events:none;z-index:50;
    font:500 14px/1.35 -apple-system,system-ui,sans-serif;color:#fff;background:#3b82ff;
    box-shadow:0 6px 22px rgba(30,80,200,.35),0 1px 2px rgba(0,0,0,.2);
    opacity:0;transform:scale(.85);transform-origin:0 0;transition:opacity .22s,transform .3s cubic-bezier(.3,1.5,.5,1);will-change:left,top}
  #bubble.on{opacity:1;transform:none}
  #bubble.you{background:rgba(24,24,28,.84);-webkit-backdrop-filter:blur(14px);color:rgba(255,255,255,.92);font-style:italic;
    box-shadow:0 6px 22px rgba(0,0,0,.3)}
  #bubble.dim{opacity:.55}
  #bubble.you.miss{color:rgba(255,255,255,.72);background:rgba(24,24,28,.7)}
  #bubble.left{transform-origin:100% 0}
  /* Reading (quiet mode, a typed answer when the box is gone, something to paste): the whole answer, parked where
     it opened, in a deeper blue so long text reads at 4.5:1. It takes clicks: scroll, Copy, ✕. */
  #bubble.read{max-width:380px;padding:9px 13px 9px;background:#2563eb;line-height:1.45;font-weight:450}
  #bubble.live{pointer-events:auto;cursor:default}
  #bubble.calm{transform:none;transition:opacity .22s}
  #bubble .txt{display:block;max-height:min(46vh,420px);overflow-y:auto;overscroll-behavior:contain;white-space:pre-wrap;
    overflow-wrap:anywhere;user-select:text;-webkit-user-select:text;scrollbar-width:thin}
  #bubble .txt::-webkit-scrollbar{width:6px}
  #bubble .txt::-webkit-scrollbar-thumb{background:rgba(255,255,255,.35);border-radius:3px}
  #bubble.snip .txt{border-left:2px solid rgba(255,255,255,.55);padding-left:9px}
  #bubble .foot{display:flex;gap:4px;justify-content:flex-end;align-items:center;margin:7px -4px -2px 0}
  #bubble .foot button{font:600 12px/1 -apple-system,system-ui,sans-serif;color:#fff;background:rgba(255,255,255,.18);border:0;
    border-radius:999px;padding:5px 11px;cursor:pointer}
  /* Hover is .hot and pressed .down, from the shared hover module (overlay.html: the overlay is never the key
     window, so WebKit's own :hover can't be relied on there). On the blue bubble the ring is white. */
  #bubble .foot button.hot{background:rgba(255,255,255,.34);box-shadow:0 0 0 1.5px rgba(255,255,255,.75)}
  #bubble .foot button.down{background:rgba(255,255,255,.12)}
  #bubble .foot button.x{background:transparent;color:rgba(255,255,255,.7);padding:5px 7px}
  #bubble .foot button.x.hot{color:#fff;background:rgba(255,255,255,.18);box-shadow:0 0 0 1.5px rgba(255,255,255,.6)}
  .sb-ripple{position:absolute;width:34px;height:34px;margin:-17px 0 0 -17px;border-radius:50%;border:2.5px solid #3b82ff;
    pointer-events:none;z-index:49;animation:sbRipple .6s ease-out forwards;box-shadow:0 0 10px rgba(59,130,255,.6)}
  @keyframes sbRipple{from{transform:scale(.3);opacity:1}to{transform:scale(1.4);opacity:0}}
  .sb-glance{position:absolute;width:34px;height:34px;margin:-17px 0 0 -17px;border-radius:50%;pointer-events:none;z-index:49;
    border:1.5px solid rgba(255,255,255,.9);box-shadow:0 0 10px rgba(160,200,255,.7),inset 0 0 6px rgba(255,255,255,.5);
    opacity:0;animation:sbGlance .5s cubic-bezier(.2,.7,.3,1) forwards}
  @keyframes sbGlance{0%{transform:scale(.35);opacity:0}30%{opacity:.85}100%{transform:scale(1.15);opacity:0}}
  .sb-glance.calm{animation:sbGlanceCalm .55s ease-out forwards}
  @keyframes sbGlanceCalm{0%{opacity:0}30%{opacity:.7}100%{opacity:0}}
  .sb-edge{position:fixed;inset:0;pointer-events:none;z-index:48;opacity:0;
    box-shadow:inset 0 0 0 1.5px rgba(255,255,255,.32),inset 0 0 28px rgba(120,170,255,.22);animation:sbEdge .7s ease-out forwards}
  @keyframes sbEdge{0%{opacity:0}25%{opacity:1}100%{opacity:0}}
  #hud.buddy{display:none}
  body.talking .pill.marking{display:none}

  `;
  const style = document.createElement('style');
  style.textContent = css;
  document.head.appendChild(style);

  // Which way a caption, label or note reads: right to left when most of its letters are Hebrew or Arabic, so the
  // period of "Python היא שפת תכנות." lands on the left (dir="auto" goes by the first letter: "P", left to right).
  // Shared with overlay.html and lesson.js.
  window.textDir = window.textDir || function (s) {
    s = String(s || '');
    const rtl = (s.match(/[\u0590-\u08FF\uFB1D-\uFDFF\uFE70-\uFEFF]/g) || []).length;
    if (!rtl) return 'ltr';
    const ltr = (s.match(/[A-Za-z\u00C0-\u024F\u0370-\u03FF\u0400-\u04FF]/g) || []).length;
    return rtl >= ltr ? 'rtl' : 'ltr';
  };

  const buddy = document.createElement('div');
  buddy.id = 'buddy';
  buddy.innerHTML = '<div class="ring"></div>' +
    '<svg class="tri" width="29" height="29" viewBox="-3 -3 26 26"><path d="M2,2 L17,8 L8,17 Z"/></svg>' +
    '<div class="dots"><i></i><i></i><i></i></div>';
  const ring = buddy.querySelector('.ring');
  const bubble = document.createElement('div');
  bubble.id = 'bubble';
  bubble.dir = 'auto';   // Hebrew or Arabic reads right to left (set per text by textDir)
  document.body.append(buddy, bubble);
  const hud = document.getElementById('hud');

  // ---------- state ----------
  let buddyOn = true, shown = true, phase = 'off', guide = false, level = 0;
  let cursor = null;                         // where your cursor is (points), or null (other screen)
  const B = { x: -200, y: -200, vx: 0, vy: 0, placed: false };
  let fly = null;                            // {x, y, until, pokeAt}: Claude is pointing at something
  let home = null;                           // {x, y, fx, fy}: showing you where it lives (the notch), facing fx,fy
  let tucked = false, blink = false;         // gone into its home; hidden for a moment (Reduced Motion's fade)
  let look = null, lookRot = 0;              // a helper it's facing (id), and the extra turn
  let bubbleKind = null, bubbleText = '', bubbleW = 0, bubbleH = 0, fadeTimer = 0;
  // Reading: the whole answer, parked where it opened ({ax, ay, left, up}: the edge it grows from), and once it's
  // done its Copy button. mode: 'speech' (the sentence being said) or 'read'.
  let mode = 'speech', parked = null, done = null, lingerTimer = 0, hovered = false, lastRect = '';
  const OFFSET = { x: 20, y: 23 };           // its tip sits this far below-right of the real cursor
  const BODY = { w: 21, h: 21 };             // its size, measured from the tip
  const MARGIN = 8;                          // never closer to the screen's edge than this
  const calm = matchMedia('(prefers-reduced-motion: reduce)').matches;

  // Which side of the cursor it runs on (flips near the right / bottom edge), and the turn-around.
  const side = { x: 1, y: 1 }, flip = { x: 1, y: 1 };
  let lastMoveAt = performance.now(), lastTick = null, wasVisible = false, hiddenFor = 0;

  // ---------- small reactions (appearing, switching sides, pointing, done talking) ----------
  let action = null;                         // {type, start, dur}
  function act(type, dur) { if (!calm) action = { type, start: performance.now(), dur }; }
  const ease = p => p < .5 ? 2 * p * p : 1 - Math.pow(-2 * p + 2, 2) / 2;
  function pose(now) {
    const o = { dx: 0, dy: 0, rot: 0, sx: 1, sy: 1 };
    if (!action) return o;
    const p = (now - action.start) / action.dur;
    if (p >= 1) { action = null; return o; }
    const s = Math.sin(p * Math.PI), bounce = Math.abs(Math.sin(p * Math.PI * 2));
    switch (action.type) {
      case 'hop':      // one small hop (switching sides at a screen edge)
        o.dy = -4 * s; break;
      case 'happy':    // a tiny bounce: done talking
        o.dy = -3 * s; break;
      case 'pop': {    // appearing
        const k = p < .6 ? .5 + .56 * (p / .6) : 1.06 - .06 * ease((p - .6) / .4);
        o.sx = o.sy = k; break;
      }
      case 'squash': { // a helper buds off it: it squeezes, then springs back
        o.sx = 1 + .22 * s; o.sy = 1 - .2 * s; break;
      }
      case 'poke': {   // a small tap toward what Claude is pointing at
        const d = -3 * Math.abs(Math.sin(p * Math.PI * 2)) * (1 - p * .5);
        o.dx = d * .7; o.dy = d * .7; break;
      }
      case 'crouch': { // about to take off: it dips and squeezes, then springs up
        o.sx = 1 + .14 * s; o.sy = 1 - .16 * s; o.dy = 2 * s; break;
      }
      case 'tuck': {   // slipping into its home: up a little and shrinking away
        const e = ease(p);
        o.sx = o.sy = 1 - .9 * e; o.dy = -12 * e; break;
      }
    }
    return o;
  }

  // ---------- the spring that makes it follow with a little wobble ----------
  let last = performance.now();
  function frame(now) {
    const dt = Math.min(1 / 30, (now - last) / 1000); last = now;
    let flying = fly && now < fly.until;
    if (fly && !flying) fly = null;
    if (home) flying = true;
    const anchor = home || (flying ? fly : cursor);
    if (anchor) {
      // Near the right or bottom edge it moves to the other side of the cursor (with a hop).
      const off = flying ? { x: 0, y: 0 } : OFFSET;
      const nx = anchor.x + off.x + BODY.w + MARGIN > innerWidth ? -1
        : anchor.x + off.x + BODY.w + MARGIN + 40 < innerWidth ? 1 : side.x;
      const ny = anchor.y + off.y + BODY.h + MARGIN > innerHeight ? -1
        : anchor.y + off.y + BODY.h + MARGIN + 40 < innerHeight ? 1 : side.y;
      if ((nx !== side.x || ny !== side.y) && B.placed && !action) act('hop', 420);
      side.x = nx; side.y = ny;
      // Its tip, kept fully on screen whichever way it faces.
      const lo = { x: MARGIN + (side.x < 0 ? BODY.w : 0), y: MARGIN + (side.y < 0 ? BODY.h : 0) };
      const hi = { x: innerWidth - MARGIN - (side.x > 0 ? BODY.w : 0), y: innerHeight - MARGIN - (side.y > 0 ? BODY.h : 0) };
      const clampX = v => Math.min(hi.x, Math.max(lo.x, v)), clampY = v => Math.min(hi.y, Math.max(lo.y, v));
      const tx = clampX(anchor.x + side.x * off.x), ty = clampY(anchor.y + side.y * off.y);
      if (!B.placed) { B.x = tx; B.y = ty; B.vx = B.vy = 0; B.placed = true; side.x = nx; side.y = ny; flip.x = nx; flip.y = ny; }
      // Under-damped: it runs a step behind you, overshoots a touch, then settles.
      // Home: a slower, graceful flight with a little overshoot (one spring family: stiffness/damping only).
      const k = home ? 70 : flying ? 120 : 300, c = home ? 12 : flying ? 15 : 22;
      B.vx += ((tx - B.x) * k - B.vx * c) * dt;
      B.vy += ((ty - B.y) * k - B.vy * c) * dt;
      B.x += B.vx * dt; B.y += B.vy * dt;
      // An overshoot never carries it off screen.
      const cx = clampX(B.x), cy = clampY(B.y);
      if (cx !== B.x) { B.x = cx; B.vx *= -.3; }
      if (cy !== B.y) { B.y = cy; B.vy *= -.3; }
    }
    // Turning around: it squeezes thin and opens up facing the other way.
    flip.x += (side.x - flip.x) * Math.min(1, dt * 12);
    flip.y += (side.y - flip.y) * Math.min(1, dt * 12);
    const fx = (flip.x < 0 ? -1 : 1) * Math.max(.12, Math.abs(flip.x));
    const fy = (flip.y < 0 ? -1 : 1) * Math.max(.12, Math.abs(flip.y));

    const visible = !!(buddyOn && shown && phase !== 'off' && (cursor || flying) && !tucked && !blink);
    if (visible !== wasVisible) buddy.classList.toggle('on', visible);
    if (visible && !wasVisible) act('pop', 420);
    if (!visible) hiddenFor += dt; else hiddenFor = 0;
    wasVisible = visible;
    // Hidden (no session, helpers working): keep following the cursor, but don't redraw.
    if (hiddenFor > .4) { requestAnimationFrame(frame); return; }

    const speed = Math.hypot(B.vx, B.vy);
    const idle = now - lastMoveAt;
    let bob = 0, rot = Math.max(-12, Math.min(12, B.vx * 0.012)), breathe = 1;
    if (!calm) {
      // Only gentle, purposeful motion: a soft breath at rest, a slight nod while it talks.
      if (phase === 'speaking') bob += Math.sin(now / 160) * .6;
      else if (idle > 1500 && !flying) breathe = 1 + .02 * Math.sin(now / 900);
      if (fly && fly.pokeAt && now >= fly.pokeAt) { fly.pokeAt = 0; act('poke', 600); }
    }
    // Facing a helper it's handing a task to (or hearing back from).
    const facing = home ? { x: home.fx, y: home.fy } : look && SB.helperPos ? SB.helperPos(look) : null;
    // The helper it faced is gone (stopped, finished and removed): it turns back, instead of keeping the turn.
    if (look && !home && !facing) look = null;
    if (facing) {
      const t = facing;
      const d0 = Math.atan2(-fy, -fx) * 180 / Math.PI;           // where its tip points now
      let want = Math.atan2(t.y - B.y, t.x - B.x) * 180 / Math.PI - d0;
      want = ((want + 540) % 360) - 180;
      lookRot += (((want - lookRot + 540) % 360) - 180) * Math.min(1, dt * 10);
    } else lookRot += (((0 - lookRot + 540) % 360) - 180) * Math.min(1, dt * 8);
    rot += lookRot;
    const P = pose(now);
    const sq = 1 + Math.min(speed / 6000, 0.08);
    const x = B.x + P.dx * side.x, y = B.y + P.dy * (P.dy < 0 ? 1 : side.y) + bob;
    buddy.style.transform = `translate(${x.toFixed(1)}px,${y.toFixed(1)}px) rotate(${(rot + P.rot).toFixed(1)}deg) ` +
      `scale(${(fx * sq * P.sx).toFixed(3)},${(fy * (2 - sq) * P.sy * breathe).toFixed(3)})`;
    if (phase === 'listening') {
      const s = 0.75 + level * 0.9 + 0.08 * Math.sin(now / 160);
      ring.style.transform = `scale(${s.toFixed(3)})`;
      ring.style.opacity = (0.35 + level * 0.65).toFixed(2);
    } else { ring.style.opacity = ''; }
    placeBubble();
    hoverButtons();
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);

  // Everything you can click lights up under the cursor the app sends (SB.tick): the shared hover module in
  // overlay.html (SBX.pointAt) sets .hot / .down; here it's fed the cursor, when it moves and a few times a
  // second (things move under a still cursor too). The bubble also remembers you're on it (it stays a while).
  let ticked = false, pointedAt = 0, pointKey = '';
  function hoverButtons() {
    if (parked && cursor && bubble.classList.contains('on'))
      hovered = cursor.x >= bubbleRectNow.x && cursor.x <= bubbleRectNow.x + bubbleW && cursor.y >= bubbleRectNow.y && cursor.y <= bubbleRectNow.y + bubbleH;
    const X = window.SBX;
    if (!ticked) return;
    if (!X || !X.pointAt) {   // buddy.js on its own (a test page without the overlay): just the bubble's buttons
      for (const b of bubble.querySelectorAll('.foot button')) {
        const r = b.getBoundingClientRect();
        b.classList.toggle('hot', !!(parked && cursor && cursor.x >= r.left && cursor.x <= r.right && cursor.y >= r.top && cursor.y <= r.bottom));
      }
      return;
    }
    const now = performance.now(), key = cursor ? cursor.x + ',' + cursor.y : '';
    if (key === pointKey && now - pointedAt < 120) return;
    pointKey = key; pointedAt = now;
    X.pointAt(cursor);
  }
  const bubbleRectNow = { x: 0, y: 0 };

  // What the bubble keeps off: the marks on screen, cards (the paper, a model) and what the answer is about (the
  // app's subjects, SB.bubbleAvoid). Measured a few times a second, not every frame.
  let avoidApp = [], avoidList = [], avoidAt = 0, bubbleSpot = 0;
  function avoidRects() {
    const now = performance.now();
    if (now - avoidAt < 200) return avoidList;
    avoidAt = now;
    const out = avoidApp.slice();
    document.querySelectorAll('#draw > g, #cards > .card:not(.leaving)').forEach(e => {
      const r = e.getBoundingClientRect(); if (r.width || r.height) out.push({ x: r.left, y: r.top, w: r.width, h: r.height });
    });
    return (avoidList = out);
  }
  function covered(x, y) {
    let a = 0;
    for (const r of avoidRects()) {
      const w = Math.min(x + bubbleW, r.x + r.w + 8) - Math.max(x, r.x - 8), h = Math.min(y + bubbleH, r.y + r.h + 8) - Math.max(y, r.y - 8);
      if (w > 0 && h > 0) a += w * h;
    }
    return a;
  }
  function placeBubble() {
    if (!bubble.classList.contains('on')) return;
    if (parked) return placeParked();
    // Beside the buddy, on its side of the cursor.
    let x = side.x > 0 ? B.x + 28 : B.x - 28 - bubbleW;
    let y = side.y > 0 ? B.y + 4 : B.y - 8 - bubbleH;
    let left = side.x < 0;
    if (!left && x + bubbleW > innerWidth - 12) { x = B.x - 14 - bubbleW; left = true; }
    if (side.y > 0 && y + bubbleH > innerHeight - 12) y = B.y - bubbleH - 10;
    const clampX = v => Math.min(innerWidth - bubbleW - 8, Math.max(8, v)), clampY = v => Math.min(innerHeight - bubbleH - 8, Math.max(8, v));
    // Over a mark, a card or what's being explained: the buddy's other corners, the one covering least (and it
    // stays put unless another is clearly better, so it doesn't hop about while you move).
    const spots = [[x, y, left], [B.x + 28, B.y + 4, false], [B.x + 28, B.y - 8 - bubbleH, false], [B.x - 14 - bubbleW, B.y + 4, true], [B.x - 14 - bubbleW, B.y - 8 - bubbleH, true]]
      .map(([sx, sy, l]) => { const cx = clampX(sx), cy = clampY(sy); return { x: cx, y: cy, left: l, c: covered(cx, cy) }; });
    let pick = spots[Math.min(bubbleSpot, spots.length - 1)];
    if (spots[0].c === 0) pick = spots[0];
    else {
      const best = spots.reduce((p, q) => q.c < p.c ? q : p);
      if (best.c < pick.c - 150) pick = best;
    }
    bubbleSpot = spots.indexOf(pick);
    bubble.classList.toggle('left', pick.left);
    bubble.style.left = pick.x.toFixed(1) + 'px';
    bubble.style.top = pick.y.toFixed(1) + 'px';
  }

  function setBubble(kind, text, extra) {
    clearTimeout(fadeTimer);
    if (!buddyOn || !shown || !text) {
      if (!kind || kind === bubbleKind) { bubble.classList.remove('on'); bubbleKind = null; unpark(); }
      return;
    }
    if (kind === 'claude' && mode === 'read') return setReading(text);
    unpark();
    bubbleKind = kind; bubbleText = text;
    bubble.className = (kind === 'you' ? 'you' : '') + (extra ? ' ' + extra : '');
    // Your words are dimmed while Claude thinks about them (the question can arrive after the phase).
    if (kind === 'you' && phase === 'thinking') bubble.classList.add('dim');
    bubble.textContent = kind === 'you' ? latestWords(text) : text;
    bubble.dir = window.textDir(bubble.textContent);
    bubbleW = bubble.offsetWidth; bubbleH = bubble.offsetHeight;
    bubble.classList.add('on');
    placeBubble();
  }

  // ---------- reading: the whole answer, parked, with Copy ----------
  function setReading(text) {
    const box = bubble.querySelector('.txt');
    const atEnd = !box || box.scrollTop + box.clientHeight >= box.scrollHeight - 4;
    if (!box || bubbleKind !== 'claude' || !parked || done || !bubble.classList.contains('on')) {
      unpark();   // a new answer (or the last one went away): a fresh bubble beside the buddy
      bubble.className = 'read' + (calm ? ' calm' : '');
      bubble.innerHTML = '<span class="txt" dir="auto"></span>';
    }
    bubbleKind = 'claude'; bubbleText = text;
    const t = bubble.querySelector('.txt');
    if (t.textContent !== text) t.textContent = text;
    bubble.classList.add('on');
    if (!parked) park();
    measure();
    if (atEnd) t.scrollTop = t.scrollHeight;   // new words come in at the bottom, unless you scrolled up to re-read
    placeParked();
  }
  function measure() { bubbleW = bubble.offsetWidth; bubbleH = bubble.offsetHeight; }
  // Where it opens: beside the buddy, like a caption, then it stays there while the buddy follows you.
  function park() {
    measure();
    const left = side.x < 0 || B.x + 28 + bubbleW > innerWidth - 12, up = side.y < 0 || B.y + 4 + Math.min(bubbleH, 160) > innerHeight - 12;
    parked = { left, up, ax: left ? B.x - 14 : B.x + 28, ay: up ? B.y - 10 : B.y + 4 };
    bubble.classList.add('live');
  }
  function placeParked() {
    const p = parked; if (!p) return;
    let x = p.left ? p.ax - bubbleW : p.ax, y = p.up ? p.ay - bubbleH : p.ay;
    x = Math.min(innerWidth - bubbleW - 8, Math.max(8, x));
    y = Math.min(innerHeight - bubbleH - 8, Math.max(8, y));
    bubble.classList.toggle('left', p.left);
    bubble.style.left = x.toFixed(1) + 'px'; bubble.style.top = y.toFixed(1) + 'px';
    bubbleRectNow.x = x; bubbleRectNow.y = y;
    reportRect(x, y);
  }
  function reportRect(x, y) {
    const r = parked && bubble.classList.contains('on') ? [Math.round(x), Math.round(y), Math.round(bubbleW), Math.round(bubbleH)] : null;
    const k = JSON.stringify(r);
    if (k === lastRect) return;
    lastRect = k;
    post({ kind: 'bubble', rect: r });
  }
  function unpark() {
    clearTimeout(lingerTimer);
    if (!parked && !done) return;
    parked = null; done = null; hovered = false;
    bubble.classList.remove('live', 'read', 'snip', 'calm');
    reportRect();
  }
  function post(m) { try { window.webkit.messageHandlers.sb.postMessage(m); } catch (e) {} }
  // The answer is done: a Copy button (and ✕). `keep`: it stays until the next question, ✕ or a click elsewhere
  // (a short line goes by itself after a while). Not kept (it was said out loud): the part to paste stays a while.
  function captionDone(copy, keep) {
    if (keep) {
      if (mode !== 'read' || bubbleKind !== 'claude' || !parked || !bubbleText) return;   // nothing being read
      done = { copy: copy || bubbleText, keep: true };
    } else {
      // Said out loud: the bubble shows only the part to paste, with Copy.
      if (!copy || !buddyOn || !shown) return;
      unpark();
      setReading(copy);
      bubble.classList.add('snip');
      done = { copy, keep: false };
    }
    const f = document.createElement('div'); f.className = 'foot';
    // "Copy text": only the part to paste (a rewrite, a command), not the whole answer.
    const label = keep && done.copy !== bubbleText ? 'Copy text' : 'Copy';
    f.innerHTML = `<button class="copy" title="${keep && done.copy !== bubbleText ? 'Copy just the text to use' : 'Copy'}">${label}</button><button class="x" title="Close" aria-label="Close">✕</button>`;
    f.querySelector('.copy').onclick = e => {
      e.stopPropagation();
      if (done) post({ kind: 'copy', text: done.copy });
      const b = e.currentTarget; b.textContent = 'Copied ✓';
      setTimeout(() => { if (b.isConnected) b.textContent = label; }, 1400);
    };
    f.querySelector('.x').onclick = e => { e.stopPropagation(); away(); };
    for (const b of f.querySelectorAll('button')) {
      b.onmousedown = () => b.classList.add('down');
      b.onmouseup = b.onmouseleave = () => b.classList.remove('down');
    }
    bubble.appendChild(f);
    measure(); placeParked();
    const words = String(bubbleText).split(/\s+/).filter(Boolean).length;
    if (!keep) linger(12000);
    else if (words < 12 && done.copy === bubbleText) linger(6000);   // "Quiet mode is on.": no need to click it away
  }
  // Goes by itself after `ms`, but never while the mouse is on it.
  function linger(ms) {
    clearTimeout(lingerTimer);
    lingerTimer = setTimeout(() => { if (hovered) linger(2500); else away(); }, ms);
  }
  // Put away (✕, a click elsewhere, lingered long enough): it fades where it is.
  function away() {
    if (!parked && !done) return;
    clearTimeout(lingerTimer);
    bubble.classList.remove('on', 'live');
    bubbleKind = null; done = null; hovered = false; parked = null;
    reportRect();
  }
  bubble.addEventListener('mouseenter', () => { hovered = true; });
  bubble.addEventListener('mouseleave', () => { hovered = false; });

  // A long question shows its end (what you're saying now), not a bubble growing down the screen.
  function latestWords(t) {
    t = String(t).trim();
    if (t.length <= YOU_MAX) return t;
    const tail = t.slice(-YOU_MAX), cut = tail.indexOf(' ');
    return '…' + (cut > 0 && cut < 24 ? tail.slice(cut + 1) : tail);
  }
  const YOU_MAX = 150;

  // The sentence being spoken right now (captions arrive as the whole answer so far).
  // A sentence ends at . ! ? … before a capital, a digit or another script's letter, but not
  // after "e.g." / "Dr." and the like (the voice doesn't pause there either). Markdown marks go.
  const ABBREV = /(?:^|\s)(?:e\.g|i\.e|vs|etc|mr|mrs|ms|dr|prof|st|approx|fig|cf)\.$/i;
  function latestSentence(t) {
    t = String(t).replace(/\*\*(.+?)\*\*/g, '$1').replace(/__(.+?)__/g, '$1').replace(/`/g, '').trim();
    const raw = t.split(/(?<=[.!?…]["'”’)\]]*)\s+(?=["'“‘(]?[\p{Lu}\p{Lo}\d])/u).filter(Boolean);
    const parts = [];
    for (const p of raw) {
      if (parts.length && ABBREV.test(parts[parts.length - 1])) parts[parts.length - 1] += ' ' + p;
      else parts.push(p);
    }
    let s = parts.pop() || t;
    if (s.length < 14 && parts.length) s = parts.pop() + ' ' + s;
    return s.length > 220 ? '…' + s.slice(-220) : s;
  }
  SB.captionSentence = latestSentence;   // for tools/tests/captions.html

  // ---------- captions go to the bubble ----------
  const caption0 = SB.caption, fade0 = SB.fadeCaptions, apply0 = SB.apply;
  SB.caption = function (which, text) {
    caption0.call(SB, which, text);
    if (which === 'you') setBubble('you', text);
    else setBubble('claude', text ? (mode === 'read' ? String(text) : latestSentence(text)) : null);
  };
  SB.fadeCaptions = function () {
    fade0.call(SB);
    if (done) return;   // an answer kept to read or copy goes when you're done with it
    if (buddyOn) { clearTimeout(fadeTimer); fadeTimer = setTimeout(() => { bubble.classList.remove('on'); bubbleKind = null; unpark(); }, 300); }
  };

  // ---------- the buddy points at what Claude marks ----------
  SB.apply = function (spec, k) {
    apply0.call(SB, spec, k);
    if (!buddyOn || !spec || !spec.items) return;
    k = k || 1;
    const it = spec.items.find(i => i && i.type && i.type !== 'panel' && i.type !== 'scene3d');
    if (!it) return;
    const n = v => (+v || 0) * k;
    let p = null;
    switch (it.type) {
      case 'circle': p = { x: n(it.x) + n(it.r) * 0.72, y: n(it.y) + n(it.r) * 0.72 }; break;
      case 'box': case 'highlight': p = { x: n(it.x) + n(it.w), y: n(it.y) + n(it.h) }; break;
      case 'underline': p = { x: n(it.x) + n(it.w), y: n(it.y) + 4 }; break;
      case 'arrow': p = { x: n(it.x2), y: n(it.y2) }; break;
      case 'bracket': p = { x: n(it.x) - 30, y: n(it.y) + n(it.h) / 2 - 8 }; break;
      default: if (it.x != null && it.y != null) p = { x: n(it.x), y: n(it.y) };
    }
    if (!p || !isFinite(p.x) || !isFinite(p.y)) return;
    const t = performance.now();
    fly = { x: p.x + 4, y: p.y + 4, until: t + (guide ? 2600 : 1900), pokeAt: t + 600 };
  };

  // ---------- API for the app ----------
  Object.assign(SB, {
    /** What this answer is about (rects in points, [x, y, w, h]): the speech bubble stays off it. */
    bubbleAvoid(rs) { avoidApp = (rs || []).map(r => ({ x: +r[0], y: +r[1], w: +r[2], h: +r[3] })); avoidAt = 0; },
    /** For tests: where the bubble is ({x, y, w, h}). */
    bubbleBox() { const r = bubble.getBoundingClientRect(); return { x: r.left, y: r.top, w: r.width, h: r.height, on: bubble.classList.contains('on') }; },
    /** Cursor position in points (or null when it's on another screen), and the mic level 0…1. */
    tick(x, y, l) {
      const now = performance.now();
      cursor = x == null ? null : { x, y };
      if (!ticked) { ticked = true; document.documentElement.classList.add('sb-tracked'); }
      level = +l || 0;
      if (cursor && lastTick && Math.hypot(x - lastTick.x, y - lastTick.y) > 1.5) lastMoveAt = now;
      lastTick = cursor;
    },
    /** off · starting · ready · listening · thinking · speaking; `g`: a walkthrough is running. */
    phase(p, g) {
      const was = phase;
      phase = p || 'off'; guide = !!g;
      if (was === 'speaking' && phase === 'ready' && !fly) act('happy', 700);
      document.body.classList.toggle('talking', phase === 'listening');
      buddy.classList.toggle('listening', phase === 'listening');
      buddy.classList.toggle('thinking', phase === 'thinking' || phase === 'starting');
      if (phase === 'thinking' && bubbleKind === 'you') bubble.classList.add('dim'); else bubble.classList.remove('dim');
      if (phase === 'listening' && bubbleKind === 'claude' && !done && mode !== 'read') setBubble(null, null);   // (an answer kept to read stays)
      if (phase === 'off') { setBubble(null, null); unpark(); fly = null; home = null; tucked = blink = false; B.placed = false; }
    },
    /** You held the keys but nothing was heard: a quiet note in your bubble that goes away by itself
     *  (the next caption replaces it at once). */
    youMissed(text) {
      setBubble('you', text, 'miss');
      if (bubbleKind === 'you') fadeTimer = setTimeout(() => { bubble.classList.remove('on'); bubbleKind = null; }, 1800);
    },
    /** 'read': captions show the whole answer, parked where it opened (quiet mode, typed answers); 'speech': the
     *  sentence being said, next to the buddy. */
    captionMode(m) { mode = m === 'read' ? 'read' : 'speech'; },
    captionDone,
    /** A click somewhere else: a bubble kept for reading or copying goes away. */
    bubbleAway() { away(); },
    /** For tests: what the bubble shows. */
    bubbleState() {
      const r = bubble.getBoundingClientRect(), t = bubble.querySelector('.txt');
      return { on: bubble.classList.contains('on'), kind: bubbleKind, text: t ? t.textContent : bubble.textContent, cls: bubble.className,
               mode, parked: !!parked, copy: done ? done.copy : null, live: bubble.classList.contains('live'),
               scroll: t ? { top: t.scrollTop, height: t.scrollHeight, view: t.clientHeight } : null,
               x: Math.round(r.left), y: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height),
               buddy: B.placed ? { x: Math.round(B.x), y: Math.round(B.y) } : null, phase, shown, buddyOn,
               visible: buddy.classList.contains('on'), vw: innerWidth, vh: innerHeight, look, lookRot: Math.round(lookRot) };
    },
    /** Hide the buddy for now (it comes back when you ask something). */
    buddyShow(on) {
      shown = !!on;
      if (!shown) { bubble.classList.remove('on'); bubbleKind = null; }
      else B.placed = false;   // reappear right at the cursor, not flying in from where it was
    },
    /** Poinky is clicking here for you (points): a small ring, a moment after the cursor arrives. */
    ripple(x, y) {
      setTimeout(() => {
        const r = document.createElement('div'); r.className = 'sb-ripple';
        r.style.left = x + 'px'; r.style.top = y + 'px';
        document.body.appendChild(r); setTimeout(() => r.remove(), 700);
      }, 380);
    },
    /** A screenshot just went to Claude: a quick glint on the buddy (a fade only with Reduced Motion),
     *  or a faint glow around the screen's edge while the buddy is hidden or elsewhere. */
    glance() {
      const visible = buddyOn && buddy.classList.contains('on') && B.placed;
      const el = document.createElement('div');
      if (visible) {
        el.className = 'sb-glance' + (calm ? ' calm' : '');
        el.style.left = (B.x + 8) + 'px'; el.style.top = (B.y + 8) + 'px';
      } else {
        el.className = 'sb-edge';
      }
      document.body.appendChild(el);
      setTimeout(() => el.remove(), 800);
    },
    /** Where your mouse is on this screen (points), or null. */
    cursorPos() { return cursor; },
    /** Where the buddy's tip is (points), for helpers to bud from and fly back to. */
    buddyPos() {
      if (B.placed) return { x: B.x, y: B.y };
      return cursor ? { x: cursor.x + OFFSET.x, y: cursor.y + OFFSET.y } : null;
    },
    /** Helpers tell the buddy what's happening: bud, handoff, handoffEnd, report, absorb. */
    buddyReact(kind, d) {
      if (kind === 'bud') act('squash', 420);
      else if (kind === 'handoff' || kind === 'report') look = d && d.id;
      else if (kind === 'handoffEnd') look = null;
      else if (kind === 'absorb') { look = null; act('happy', 600); }
    },
    /** "I live here" (first run): fly up to (x, y) under the notch or the menu bar icon, facing (fx, fy).
     *  Reduced Motion: it fades out at the cursor and fades in there instead of flying. */
    homeGo(x, y, fx, fy) {
      const was = home;
      home = { x, y, fx, fy };
      tucked = false;
      if (calm) {
        blink = true;
        setTimeout(() => { B.x = x; B.y = y; B.vx = B.vy = 0; B.placed = true; blink = false; }, 320);
      } else if (!was && B.placed) {
        act('crouch', 260);
        B.vy -= 220;   // a little lift as it takes off
      }
    },
    /** It goes into its home (the caption goes too); `SB.phase('off')` later resets it for the next session. */
    homeEnd() {
      setBubble(null, null);
      if (calm) { tucked = true; return; }
      act('tuck', 460);
      setTimeout(() => { tucked = true; }, 440);
    },
    /** For tests: where it is and what it's doing. */
    homeState() {
      return { x: B.x, y: B.y, home: !!home, tucked, blink, visible: buddy.classList.contains('on'),
               bubble: bubble.classList.contains('on') ? bubble.textContent : '', calm,
               transform: buddy.style.transform };
    },
    buddyOn(on) {
      buddyOn = !!on;
      hud.classList.toggle('buddy', buddyOn);
      if (!buddyOn) setBubble(null, null);
    },
  });
  hud.classList.add('buddy');
})();

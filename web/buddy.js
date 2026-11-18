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

  const buddy = document.createElement('div');
  buddy.id = 'buddy';
  buddy.innerHTML = '<div class="ring"></div>' +
    '<svg class="tri" width="29" height="29" viewBox="-3 -3 26 26"><path d="M2,2 L17,8 L8,17 Z"/></svg>' +
    '<div class="dots"><i></i><i></i><i></i></div>';
  const ring = buddy.querySelector('.ring');
  const bubble = document.createElement('div');
  bubble.id = 'bubble';
  bubble.dir = 'auto';   // Hebrew or Arabic reads right to left
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
    if (facing || look) {
      const t = facing;
      if (t) {
        const d0 = Math.atan2(-fy, -fx) * 180 / Math.PI;           // where its tip points now
        let want = Math.atan2(t.y - B.y, t.x - B.x) * 180 / Math.PI - d0;
        want = ((want + 540) % 360) - 180;
        lookRot += (((want - lookRot + 540) % 360) - 180) * Math.min(1, dt * 10);
      }
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
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);

  function placeBubble() {
    if (!bubble.classList.contains('on')) return;
    // Beside the buddy, on its side of the cursor.
    let x = side.x > 0 ? B.x + 28 : B.x - 28 - bubbleW;
    let y = side.y > 0 ? B.y + 4 : B.y - 8 - bubbleH;
    let left = side.x < 0;
    if (!left && x + bubbleW > innerWidth - 12) { x = B.x - 14 - bubbleW; left = true; }
    if (side.y > 0 && y + bubbleH > innerHeight - 12) y = B.y - bubbleH - 10;
    bubble.classList.toggle('left', left);
    bubble.style.left = Math.min(innerWidth - bubbleW - 8, Math.max(8, x)).toFixed(1) + 'px';
    bubble.style.top = Math.min(innerHeight - bubbleH - 8, Math.max(8, y)).toFixed(1) + 'px';
  }

  function setBubble(kind, text, extra) {
    clearTimeout(fadeTimer);
    if (!buddyOn || !shown || !text) {
      if (!kind || kind === bubbleKind) { bubble.classList.remove('on'); bubbleKind = null; }
      return;
    }
    bubbleKind = kind; bubbleText = text;
    bubble.className = (kind === 'you' ? 'you' : '') + (extra ? ' ' + extra : '');
    // Your words are dimmed while Claude thinks about them (the question can arrive after the phase).
    if (kind === 'you' && phase === 'thinking') bubble.classList.add('dim');
    bubble.textContent = kind === 'you' ? latestWords(text) : text;
    bubbleW = bubble.offsetWidth; bubbleH = bubble.offsetHeight;
    bubble.classList.add('on');
    placeBubble();
  }

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
    else setBubble('claude', text ? latestSentence(text) : null);
  };
  SB.fadeCaptions = function () {
    fade0.call(SB);
    if (buddyOn) { clearTimeout(fadeTimer); fadeTimer = setTimeout(() => { bubble.classList.remove('on'); bubbleKind = null; }, 300); }
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
    /** Cursor position in points (or null when it's on another screen), and the mic level 0…1. */
    tick(x, y, l) {
      const now = performance.now();
      cursor = x == null ? null : { x, y };
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
      if (phase === 'listening' && bubbleKind === 'claude') setBubble(null, null);
      if (phase === 'off') { setBubble(null, null); fly = null; home = null; tucked = blink = false; B.placed = false; }
    },
    /** You held the keys but nothing was heard: a quiet note in your bubble that goes away by itself
     *  (the next caption replaces it at once). */
    youMissed(text) {
      setBubble('you', text, 'miss');
      if (bubbleKind === 'you') fadeTimer = setTimeout(() => { bubble.classList.remove('on'); bubbleKind = null; }, 1800);
    },
    /** For tests: what the bubble shows. */
    bubbleState() {
      const r = bubble.getBoundingClientRect();
      return { on: bubble.classList.contains('on'), kind: bubbleKind, text: bubble.textContent, cls: bubble.className,
               x: Math.round(r.left), y: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height),
               buddy: B.placed ? { x: Math.round(B.x), y: Math.round(B.y) } : null, phase, shown, buddyOn,
               visible: buddy.classList.contains('on'), vw: innerWidth, vh: innerHeight };
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

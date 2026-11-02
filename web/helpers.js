// Helpers on screen: small colored cursors that bud off the main buddy, take a task, fly to the
// edge of the screen, work there with a live progress line, and fly back to report.
//
// Everything moves from update(dt) (no CSS transitions), so a timeline can be scrubbed and replayed
// exactly. Used by web/agents-lab.html now and by the overlay later.
//
//   const layer = new HelperLayer(root, {
//     main: { pos: () => ({x, y}), react: (kind, data) => {} },   // the main buddy
//     sound: (name, opts) => {},                                   // opts: {x, x2, dur, note}
//     params: {...HelperLayer.defaults},
//   });
//   layer.spawn('h1', {name: 'Mint', color: '#34c98e', task: 'Fix the failing test'});
//   layer.step('h1', 'Reading tipsplit.py');  layer.checklist('h1', [{text, state}]);
//   layer.raiseHand('h1', 'Can I run npm install?');  layer.resolveHand('h1', true);
//   layer.done('h1', {ok: true, summary: '…'});
//   each frame: layer.update(dt); layer.render();
(function (global) {
  const TAU = Math.PI * 2;
  const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
  const lerp = (a, b, t) => a + (b - a) * t;
  const easeInOut = t => t < .5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
  const easeOut = t => 1 - Math.pow(1 - t, 3);
  const easeOutBack = (t, s = 1.7) => 1 + (s + 1) * Math.pow(t - 1, 3) + s * Math.pow(t - 1, 2);
  // The cursor shape points up-left (-135°); this turns it to face an angle.
  const FACE = 135;

  // Seeded random numbers, so a replay looks exactly the same.
  function rng(seed) { let s = seed >>> 0; return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296); }

  const CSS = `
  .hl-root{position:absolute;inset:0;pointer-events:none;overflow:hidden;z-index:45;font:500 13px/1.3 -apple-system,system-ui,sans-serif}
  .hl-h{position:absolute;left:0;top:0;width:0;height:0;will-change:transform}
  .hl-tri{position:absolute;left:0;top:0;width:29px;height:29px;margin:-5.5px 0 0 -5.5px;transform-origin:5.5px 5.5px;will-change:transform;overflow:visible}
  .hl-tri path{stroke-width:4;stroke-linejoin:round}
  .hl-ring{position:absolute;left:0;top:0;width:44px;height:44px;margin:-22px 0 0 -22px;overflow:visible}
  .hl-ring circle{fill:none;stroke-linecap:round}
  .hl-bub{position:absolute;left:0;top:0;white-space:nowrap;padding:5px 10px;border-radius:11px;color:#fff;
    font:600 12.5px/1.25 -apple-system,system-ui,sans-serif;box-shadow:0 6px 18px rgba(0,0,0,.22),0 1px 2px rgba(0,0,0,.2);
    transform-origin:0 50%;opacity:0}
  .hl-chip{position:absolute;left:0;top:0;width:236px;padding:8px 11px 9px;border-radius:13px;box-sizing:border-box;
    background:rgba(28,28,32,.80);-webkit-backdrop-filter:blur(18px) saturate(1.4);backdrop-filter:blur(18px) saturate(1.4);
    box-shadow:0 8px 26px rgba(0,0,0,.28),inset 0 0 0 .5px rgba(255,255,255,.12);color:rgba(255,255,255,.92);opacity:0;will-change:transform,opacity}
  .hl-chip .top{display:flex;align-items:center;gap:6px;font:650 12px/1.2 -apple-system,system-ui,sans-serif;letter-spacing:.01em}
  .hl-chip .dot{width:8px;height:8px;border-radius:50%;flex:none}
  .hl-chip .count{margin-left:auto;font:500 11px/1 -apple-system,system-ui,sans-serif;color:rgba(255,255,255,.5);font-variant-numeric:tabular-nums}
  .hl-chip .lines{position:relative;height:17px;margin-top:4px;overflow:hidden}
  .hl-chip .ln{position:absolute;left:0;right:0;top:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-size:12.5px;color:rgba(255,255,255,.78)}
  .hl-chip .check{display:inline-block;margin-right:4px}
  .hl-p{position:absolute;left:0;top:0;border-radius:50%;will-change:transform,opacity}
  .hl-trail{position:absolute;left:0;top:0;width:6px;height:6px;margin:-3px 0 0 -3px;border-radius:50%;will-change:transform,opacity}
  .hl-wait{position:absolute;left:0;top:0;width:10px;height:10px;margin:-5px 0 0 -5px;border-radius:50%;will-change:transform,opacity}
  `;

  class HelperLayer {
    // Each helper's color, by name (AgentManager.names). Never blue: that's the main buddy.
    static colors = { Mint: '#34c98e', Coral: '#ff7a59', Violet: '#9b6bff', Amber: '#ffb020', Rose: '#ff5c9a', Sky: '#38bdf8' };
    static defaults = {
      size: .72,          // helper size, relative to the main buddy
      flight: .95,        // seconds for a flight across about half the screen
      arc: .32,           // how high flights curve
      bounce: .55,        // 0 = no overshoot, 1 = lots
      trail: 1,           // 1 = a short comet trail while flying
      particles: 1,       // amount of sparkle (0 – 2)
      typing: 1,          // how fast progress text types in
      handoff: 2.1,       // seconds the main buddy spends handing over the task
      dock: 'right',      // which edge helpers work at
      calm: false,        // Reduced Motion: fades instead of flights and bursts
    };

    constructor(root, opts) {
      this.opts = opts;
      this.params = Object.assign({}, HelperLayer.defaults, opts.params || {});
      if (!document.getElementById('hl-css')) {
        const s = document.createElement('style'); s.id = 'hl-css'; s.textContent = CSS; document.head.appendChild(s);
      }
      this.el = document.createElement('div');
      this.el.className = 'hl-root';
      root.appendChild(this.el);
      this.helpers = new Map();
      this.order = [];          // ids by slot
      this.parts = [];          // particles
      this.pool = [];
      this.time = 0;
      this.rand = rng(7);
    }

    destroy() { this.el.remove(); }
    setParams(p) { Object.assign(this.params, p); }
    get W() { return this.el.clientWidth || innerWidth; }
    get H() { return this.el.clientHeight || innerHeight; }
    sound(name, o = {}) { this.opts.sound && this.opts.sound(name, o); }
    main() { return this.opts.main.pos(); }
    react(kind, data) { this.opts.main.react && this.opts.main.react(kind, data); }

    // ---------- the API ----------

    spawn(id, { name, color, task, note = 0 }) {
      const m = this.main();
      const h = {
        id, name, color, task, note, phase: 'bud', t: 0,
        x: m.x, y: m.y, vx: 0, vy: 0, rot: 0, vrot: 0, scale: 0, alpha: 1,
        slot: this.freeSlot(), line: '', prev: '', lineT: 0, prevT: 9, count: '', items: [],
        frac: 0, fracShown: 0, chip: 0, chipX: 0, bub: '', bubT: 0, bubA: 0, ringA: 0, mood: 'work', trail: [],
        nod: -1, spin: -1, droop: 0, ask: '', handT: 0, el: null,
      };
      this.helpers.set(id, h);
      this.order[h.slot] = id;
      this.build(h);
      this.react('bud', { id, x: m.x, y: m.y });
      this.sound('spawn', { x: m.x, note });
      this.burst(m.x + 8, m.y + 8, color, 7, 70);
      return h;
    }

    step(id, text) {
      const h = this.helpers.get(id); if (!h || !text || text === h.line) return;
      h.prev = h.line; h.prevT = 0; h.line = text; h.lineT = 0;
    }

    checklist(id, items) {
      const h = this.helpers.get(id); if (!h) return;
      const done = items.filter(i => i.state === 'done').length, was = h.items.filter(i => i.state === 'done').length;
      h.items = items; h.frac = items.length ? done / items.length : 0;
      h.count = items.length ? `${done}/${items.length}` : '';
      if (done > was && h.phase === 'dock') { this.sound('tick', { x: h.x, note: h.note }); this.burst(h.x + 6, h.y + 6, h.color, 4, 40); }
      const active = items.find(i => i.state === 'active');
      if (active) this.step(id, active.text);
    }

    raiseHand(id, question) {
      const h = this.helpers.get(id); if (!h) return;
      h.ask = question;
      this.go(h, 'out', this.askSpot(h));
    }

    resolveHand(id, ok) {
      const h = this.helpers.get(id); if (!h || h.phase !== 'asking') return;
      h.phase = 'thanks'; h.t = 0; h.bub = ok ? 'Thanks!' : 'Okay, skipping it'; h.bubT = 0; h.nod = 0;
      this.sound('ack', { x: h.x, note: h.note });
    }

    done(id, { ok = true, summary = '' } = {}) {
      const h = this.helpers.get(id); if (!h) return;
      h.ok = ok; h.summary = summary;
      h.frac = ok ? 1 : h.frac; h.count = ok && h.items.length ? `${h.items.length}/${h.items.length}` : h.count;
      h.prev = h.line; h.prevT = 0; h.line = ok ? 'Done' : 'Couldn’t finish'; h.lineT = 99;
      h.phase = ok ? 'celebrate' : 'droop'; h.t = 0;
      if (ok) {
        this.sound('done', { x: h.x, note: h.note });
        h.spin = 0;
        this.burst(h.x + 7, h.y + 7, h.color, 16, 150, true);
      } else {
        this.sound('fail', { x: h.x, note: h.note });
      }
    }

    // Stopped by the user: a small puff where it was.
    stop(id) {
      const h = this.helpers.get(id); if (!h) return;
      this.burst(h.x + 6, h.y + 6, h.color, 6, 45);
      this.remove(h);
    }

    get count() { return this.helpers.size; }
    pos(id) { const h = this.helpers.get(id); return h ? { x: h.x, y: h.y } : null; }

    // ---------- layout ----------

    freeSlot() { let i = 0; while (this.order[i] !== undefined) i++; return i; }
    slotPos(h) {
      const right = this.params.dock !== 'left';
      return { x: right ? this.W - 34 : 34, y: 92 + h.slot * 66 };
    }
    askSpot(h) {
      const m = this.main(), right = this.params.dock !== 'left';
      return { x: m.x + (right ? 46 : -46), y: m.y - 30 };
    }
    // Where a new helper buds: above the main buddy, toward the edge it will fly to.
    budDir() { return { x: this.params.dock === 'left' ? -26 : 34, y: -34 }; }
    // Reporting back: in the same spot it budded from, clear of the main buddy's speech bubble.
    reportSpot() { const m = this.main(), d = this.budDir(); return { x: m.x + d.x, y: m.y + d.y }; }

    // Starts a flight to `to`; `kind` says what happens on arrival.
    go(h, kind, to) {
      const dist = Math.hypot(to.x - h.x, to.y - h.y);
      h.fly = { kind, x0: h.x, y0: h.y, to, dur: this.params.flight * (.62 + Math.min(1.1, dist / 900)), u: 0, dist };
      h.phase = 'fly'; h.t = 0; h.trail.length = 0;
      if (!this.params.calm) this.sound('whoosh', { x: h.x, x2: to.x, dur: h.fly.dur, note: h.note });
    }

    // ---------- simulation ----------

    update(dt) {
      this.time += dt;
      const P = this.params, k = 170, c = lerp(26, 12, P.bounce);
      for (const h of [...this.helpers.values()]) {
        h.t += dt; h.lineT += dt; h.prevT += dt; h.bubT += dt;
        const m = this.main();
        let tx = h.x, ty = h.y, follow = true, face = 0, targetScale = P.size;

        switch (h.phase) {
          case 'bud': {   // buds off the main buddy's tip and drifts a little away
            const u = clamp(h.t / .5, 0, 1);
            const away = this.budDir();
            const bx = m.x + away.x, by = m.y + away.y;
            h.x = lerp(m.x, bx, easeOutBack(u, 1.2)); h.y = lerp(m.y, by, easeOutBack(u, 1.2));
            h.scale = P.size * easeOutBack(clamp(h.t / .38, 0, 1), 2.2);
            follow = false;
            if (h.t >= .5) { h.phase = 'handoff'; h.t = 0; this.react('handoff', { id: h.id, name: h.name, task: h.task, x: h.x, y: h.y, color: h.color }); this.sound('handoff', { x: m.x }); }
            break;
          }
          case 'handoff': {   // the main buddy faces it and gives the task; it nods "on it"
            const away = this.budDir();
            tx = m.x + away.x; ty = m.y + away.y + Math.sin(h.t * 5) * 1.2;
            face = Math.atan2(m.y - h.y, m.x - h.x) * 180 / Math.PI + FACE;
            if (h.t >= P.handoff * .62 && h.nod < 0 && !h.bub) { h.bub = 'On it!'; h.bubT = 0; h.nod = 0; this.sound('ack', { x: h.x, note: h.note }); }
            if (h.t >= P.handoff) { h.bub = ''; this.react('handoffEnd', { id: h.id }); this.go(h, 'dock', this.slotPos(h)); }
            break;
          }
          case 'fly': {
            const f = h.fly; f.u = clamp(f.u + dt / f.dur, 0, 1);
            const to = f.kind === 'dock' ? this.slotPos(h) : f.kind === 'out' ? this.askSpot(h) : f.kind === 'report' ? this.reportSpot() : f.to;
            follow = false;
            if (P.calm) {   // Reduced Motion: fade out, then in at the destination
              h.alpha = f.u < .5 ? 1 - f.u * 2 : (f.u - .5) * 2;
              if (f.u >= .5) { h.x = to.x; h.y = to.y; }
            } else {
              const e = easeInOut(f.u);
              // A curve lifted above the straight line, like a gentle throw (it never overshoots sideways).
              const cx = (f.x0 + to.x) / 2, cy = (f.y0 + to.y) / 2 - f.dist * P.arc;
              const px = (1 - e) * (1 - e) * f.x0 + 2 * (1 - e) * e * cx + e * e * to.x;
              const py = (1 - e) * (1 - e) * f.y0 + 2 * (1 - e) * e * cy + e * e * to.y;
              h.vx = (px - h.x) / Math.max(dt, 1e-4); h.vy = (py - h.y) / Math.max(dt, 1e-4);
              h.x = px; h.y = py; h.alpha = 1;
              if (P.trail && f.u > .02 && f.u < .98) { h.trail.unshift({ x: h.x + 7, y: h.y + 7, a: 1 }); if (h.trail.length > 9) h.trail.pop(); }
            }
            const speed = Math.hypot(h.vx, h.vy);
            face = speed > 30 && f.u < .85 ? Math.atan2(h.vy, h.vx) * 180 / Math.PI + FACE : 0;
            // Stretches a touch with speed.
            targetScale = P.size * (1 + Math.min(.12, speed / 9000));
            h.scale = lerp(h.scale, targetScale, 1 - Math.exp(-dt * 14));
            if (f.u >= 1) {
              h.vx = h.vy = 0; h.trail.length = 0;
              if (f.kind === 'dock') { h.phase = 'dock'; h.t = 0; this.sound('land', { x: h.x, note: h.note }); h.squash = 0; }
              else if (f.kind === 'out') { h.phase = 'asking'; h.t = 0; h.bub = h.ask; h.bubT = 0; this.sound('hand', { x: h.x, note: h.note }); this.react('ask', { id: h.id, name: h.name, text: h.ask }); }
              else if (f.kind === 'report') {
                h.phase = 'report'; h.t = 0;
                h.reportFor = clamp(1.6 + (h.summary || '').length * .045, 2.4, 6.5);
                this.react('report', { id: h.id, name: h.name, color: h.color, ok: h.ok, summary: h.summary });
              }
            }
            break;
          }
          case 'dock': {   // working: a soft "typing" tap toward its card
            const s = this.slotPos(h); tx = s.x; ty = s.y;
            if (!P.calm) { const p = (h.t % 1.7) / .32; if (p < 1) { const d = Math.sin(p * Math.PI) * 2.2; tx -= d; ty -= d * .6; } }
            break;
          }
          case 'asking': {   // hopping gently next to you until you answer
            const a = this.askSpot(h); tx = a.x; ty = a.y - (P.calm ? 0 : Math.abs(Math.sin(h.t * 3.2)) * 5 * Math.exp(-((h.t % 4) * .9)));
            face = Math.atan2(m.y - h.y, m.x - h.x) * 180 / Math.PI + FACE;
            break;
          }
          case 'thanks': {
            const a = this.askSpot(h); tx = a.x; ty = a.y;
            if (h.t > .75) { h.bub = ''; this.go(h, 'dock', this.slotPos(h)); }
            break;
          }
          case 'celebrate': {   // a happy spin, then home
            const s = this.slotPos(h); tx = s.x; ty = s.y - (P.calm ? 0 : Math.sin(clamp(h.t / .55, 0, 1) * Math.PI) * 9);
            if (h.t > 1.05) { this.go(h, 'report', this.reportSpot()); }
            break;
          }
          case 'droop': {
            const s = this.slotPos(h); tx = s.x; ty = s.y + Math.min(4, h.t * 10);
            h.droop = lerp(h.droop, 22, 1 - Math.exp(-dt * 6));
            if (h.t > 1.1) { this.go(h, 'report', this.reportSpot()); }
            break;
          }
          case 'report': {   // next to the main buddy while it tells you
            const r = this.reportSpot(); tx = r.x; ty = r.y + Math.sin(h.t * 4) * 1;
            face = Math.atan2(m.y - h.y, m.x - h.x) * 180 / Math.PI + FACE;
            if (h.t > h.reportFor) { h.phase = 'merge'; h.t = 0; this.sound('merge', { x: m.x, note: h.note }); this.react('absorb', { id: h.id }); }
            break;
          }
          case 'merge': {   // shrinks into the main buddy
            const u = clamp(h.t / .38, 0, 1), e = easeInOut(u);
            h.x = lerp(h.x, m.x + 4, e); h.y = lerp(h.y, m.y + 4, e);
            h.scale = P.size * (1 - e); follow = false;
            if (u >= 1) { this.burst(m.x + 6, m.y + 6, h.color, 6, 50); this.remove(h); continue; }
            break;
          }
        }

        if (follow) {   // a spring toward the target: a step behind, a little overshoot
          h.vx += ((tx - h.x) * k - h.vx * c) * dt; h.vy += ((ty - h.y) * k - h.vy * c) * dt;
          h.x += h.vx * dt; h.y += h.vy * dt;
          h.scale = lerp(h.scale, targetScale, 1 - Math.exp(-dt * 12)); h.alpha = lerp(h.alpha, 1, 1 - Math.exp(-dt * 10));
        }
        // Turning, on its own spring (the shortest way around).
        let want = face + (h.phase === 'droop' || (h.phase === 'report' && h.ok === false) ? h.droop : 0);
        let diff = ((want - h.rot) % 360 + 540) % 360 - 180;
        h.vrot += (diff * 140 - h.vrot * 18) * dt; h.rot += h.vrot * dt;
        if (h.nod >= 0) { h.nod += dt; if (h.nod > .5) h.nod = -1; }
        if (h.spin >= 0) { h.spin += dt; if (h.spin > .7) h.spin = -1; }
        if (h.squash !== undefined && h.squash >= 0) { h.squash += dt; if (h.squash > .3) h.squash = -1; }
        // Card: shown while it works at the edge.
        const showChip = ['dock', 'celebrate', 'droop'].includes(h.phase) || (h.phase === 'fly' && h.fly.kind === 'dock' && h.fly.u > .93);
        const dimChip = ['asking', 'thanks'].includes(h.phase) || (h.phase === 'fly' && h.fly.kind === 'out');
        h.chip = lerp(h.chip, showChip ? 1 : dimChip ? .55 : 0, 1 - Math.exp(-dt * 9));
        h.chipX = lerp(h.chipX, showChip || dimChip ? 0 : 1, 1 - Math.exp(-dt * 9));
        h.fracShown = lerp(h.fracShown, h.frac, 1 - Math.exp(-dt * 6));
        // Fades, advanced with time (not per drawn frame) so a scrubbed timeline looks the same.
        const working = ['dock', 'celebrate', 'droop'].includes(h.phase);
        h.ringA = lerp(h.ringA, working ? 1 : 0, 1 - Math.exp(-dt * 10));
        h.bubA = lerp(h.bubA, h.bub ? 1 : 0, 1 - Math.exp(-dt * 16));
        for (const p of h.trail) p.a -= dt * 4;
      }
      // Particles
      for (const p of this.parts) {
        p.life += dt; p.vx *= Math.exp(-dt * 3.2); p.vy = p.vy * Math.exp(-dt * 3.2) + 40 * dt;
        p.x += p.vx * dt; p.y += p.vy * dt;
      }
      this.parts = this.parts.filter(p => p.life < p.max);
    }

    burst(x, y, color, n, speed, sparkle) {
      if (this.params.calm) return;
      n = Math.round(n * this.params.particles);
      for (let i = 0; i < n; i++) {
        const a = (i / n) * TAU + this.rand() * .5, v = speed * (.55 + this.rand() * .6);
        this.parts.push({ x, y, vx: Math.cos(a) * v, vy: Math.sin(a) * v - speed * .15, life: 0, max: .55 + this.rand() * .35,
          size: 2.5 + this.rand() * 3, color: sparkle && i % 3 === 0 ? '#fff' : color });
      }
    }

    remove(h) {
      h.el && h.el.root.remove(); h.el && h.el.chip.remove();
      h.el && h.el.trail.forEach(t => t.remove());
      this.helpers.delete(h.id);
      if (this.order[h.slot] === h.id) this.order[h.slot] = undefined;
    }

    // ---------- drawing ----------

    build(h) {
      const root = document.createElement('div'); root.className = 'hl-h';
      root.innerHTML =
        `<svg class="hl-ring" viewBox="-22 -22 44 44"><circle class="bg" r="16" stroke-width="2"/><circle class="fg" r="16" stroke-width="2.4" transform="rotate(-90)"/></svg>` +
        `<svg class="hl-tri" viewBox="-3 -3 26 26"><path d="M2,2 L17,8 L8,17 Z"/></svg>` +
        `<div class="hl-bub"></div>`;
      const path = root.querySelector('path');
      path.style.fill = h.color; path.style.stroke = h.color;
      path.style.filter = `drop-shadow(0 0 5px ${h.color}bb) drop-shadow(0 2px 3px rgba(0,0,0,.25))`;
      root.querySelector('.bg').style.stroke = h.color + '33';
      root.querySelector('.fg').style.stroke = h.color;
      const bub = root.querySelector('.hl-bub'); bub.style.background = h.color;
      const chip = document.createElement('div'); chip.className = 'hl-chip';
      chip.innerHTML = `<div class="top"><span class="dot"></span><span class="name"></span><span class="count"></span></div><div class="lines"><div class="ln prev"></div><div class="ln cur"></div></div>`;
      chip.querySelector('.dot').style.background = h.color;
      chip.querySelector('.dot').style.boxShadow = `0 0 6px ${h.color}`;
      const name = chip.querySelector('.name'); name.textContent = h.name; name.style.color = h.color;
      const trail = [];
      for (let i = 0; i < 9; i++) { const t = document.createElement('div'); t.className = 'hl-trail'; t.style.background = h.color; this.el.appendChild(t); trail.push(t); }
      this.el.appendChild(chip); this.el.appendChild(root);
      h.el = { root, tri: root.querySelector('.hl-tri'), ring: root.querySelector('.hl-ring'), fg: root.querySelector('.fg'), bub, chip, trail,
        count: chip.querySelector('.count'), prev: chip.querySelector('.prev'), cur: chip.querySelector('.cur'), cache: {} };
    }

    render() {
      const P = this.params, right = P.dock !== 'left';
      for (const h of this.helpers.values()) {
        const e = h.el, C = e.cache;
        let sx = h.scale, sy = h.scale, rot = h.rot, dy = 0;
        if (h.nod >= 0) { const p = h.nod / .5; dy += Math.sin(p * Math.PI * 2) * 3 * (1 - p); }
        if (h.spin >= 0) { const p = easeInOut(h.spin / .7); rot += p * 360; sx *= 1 + Math.sin(p * Math.PI) * .3; sy = sx; }
        if (h.squash >= 0) { const p = h.squash / .3; sx *= 1 + Math.sin(p * Math.PI) * .18; sy *= 1 - Math.sin(p * Math.PI) * .14; }
        e.root.style.transform = `translate(${h.x.toFixed(1)}px,${(h.y + dy).toFixed(1)}px)`;
        e.root.style.opacity = h.alpha.toFixed(3);
        e.tri.style.transform = `rotate(${rot.toFixed(1)}deg) scale(${sx.toFixed(3)},${sy.toFixed(3)})`;
        // Progress ring around it while it works.
        e.ring.style.opacity = h.ringA.toFixed(3);
        e.ring.style.transform = `translate(${(8.2 * h.scale).toFixed(1)}px,${(8.2 * h.scale).toFixed(1)}px) scale(${(.6 + .4 * h.scale / P.size).toFixed(3)})`;
        const L = TAU * 16;
        if (h.items.length || h.phase === 'celebrate') {
          e.fg.style.strokeDasharray = h.fracShown < .005 ? `0 ${L.toFixed(1)}` : `${(L * h.fracShown).toFixed(1)} ${L.toFixed(1)}`;
          e.fg.style.opacity = h.fracShown < .005 ? 0 : 1;
          e.fg.setAttribute('transform', 'rotate(-90)');
        } else {   // no to-do list: a slow, quiet sweep
          e.fg.style.strokeDasharray = `${(L * .22).toFixed(1)} ${L.toFixed(1)}`;
          e.fg.setAttribute('transform', `rotate(${((this.time * 140) % 360).toFixed(1)})`);
          e.fg.style.opacity = 1;
        }
        e.fg.style.stroke = h.phase === 'droop' || (h.ok === false) ? '#8b8b93' : h.color;
        // Its speech bubble ("On it!", a question).
        const bubOn = !!h.bub;
        if (C.bubText !== h.bub && h.bub) { e.bub.textContent = h.bub; C.bubText = h.bub; }
        const bs = bubOn ? easeOutBack(clamp(h.bubT / .3, 0, 1), 2) : 1;
        const bx = right ? 18 : -18 - (e.bub.offsetWidth || 60);
        e.bub.style.transformOrigin = right ? '0 50%' : '100% 50%';
        e.bub.style.transform = `translate(${bx}px,-30px) scale(${(.6 + .4 * bs).toFixed(3)})`;
        e.bub.style.opacity = h.bubA.toFixed(3);
        // The card at the edge.
        const s = this.slotPos(h);
        // It grows out of the helper, toward the middle of the screen.
        const cw = 236, cx = right ? s.x - 22 - cw + h.chipX * 10 : s.x + 30 - h.chipX * 10;
        e.chip.style.transformOrigin = right ? '100% 50%' : '0 50%';
        e.chip.style.transform = `translate(${cx.toFixed(1)}px,${(s.y - 15).toFixed(1)}px) scale(${(.86 + .14 * h.chip).toFixed(3)})`;
        e.chip.style.opacity = h.chip.toFixed(3);
        if (C.count !== h.count) { e.count.textContent = h.count; C.count = h.count; }
        // Progress text types in; the old line slides up and fades.
        const n = Math.floor(h.lineT * 45 * P.typing);
        const shown = h.line.slice(0, Math.max(0, n));
        const cur = (h.phase === 'celebrate' || (h.phase !== 'droop' && h.ok && h.line === 'Done')) ? '✓ ' + h.line : shown;
        if (C.cur !== cur) { e.cur.textContent = cur; C.cur = cur; }
        if (C.prev !== h.prev) { e.prev.textContent = h.prev; C.prev = h.prev; }
        const pu = clamp(h.prevT / .28, 0, 1);
        e.prev.style.transform = `translateY(${(-14 * easeOut(pu)).toFixed(1)}px)`; e.prev.style.opacity = (1 - pu).toFixed(3);
        const cu = clamp(h.lineT / .28, 0, 1);
        e.cur.style.transform = `translateY(${(10 * (1 - easeOut(cu))).toFixed(1)}px)`; e.cur.style.opacity = cu.toFixed(3);
        e.cur.style.color = h.phase === 'celebrate' ? h.color : '';
        // Trail
        e.trail.forEach((t, i) => {
          const p = h.trail[i];
          if (!p || p.a <= 0) { t.style.opacity = 0; return; }
          const k = 1 - i / 9;
          t.style.transform = `translate(${p.x.toFixed(1)}px,${p.y.toFixed(1)}px) scale(${(k * h.scale / P.size).toFixed(3)})`;
          t.style.opacity = (p.a * k * .55).toFixed(3);
        });
      }
      // Particles, from a pool of divs.
      while (this.pool.length < this.parts.length) { const d = document.createElement('div'); d.className = 'hl-p'; this.el.appendChild(d); this.pool.push(d); }
      this.pool.forEach((d, i) => {
        const p = this.parts[i];
        if (!p) { if (d.style.opacity !== '0') d.style.opacity = '0'; return; }
        const u = p.life / p.max;
        d.style.width = d.style.height = p.size.toFixed(1) + 'px';
        d.style.background = p.color; d.style.boxShadow = `0 0 6px ${p.color}`;
        d.style.transform = `translate(${(p.x - p.size / 2).toFixed(1)}px,${(p.y - p.size / 2).toFixed(1)}px) scale(${(1 - u * .6).toFixed(3)})`;
        d.style.opacity = (1 - u * u).toFixed(3);
      });
    }
  }

  global.HelperLayer = HelperLayer;
})(window);

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
//   With params.hold, a finished helper waits at the edge until layer.report('h1') (the app is about to
//   tell you), stays by the main buddy while it talks, and merges on layer.release('h1').
//   each frame: layer.update(dt); layer.render();
(function (global) {
  const TAU = Math.PI * 2;
  const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
  const lerp = (a, b, t) => a + (b - a) * t;
  const easeInOut = t => t < .5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
  const easeOut = t => 1 - Math.pow(1 - t, 3);
  const easeOutBack = (t, s = 1.7) => 1 + (s + 1) * Math.pow(t - 1, 3) + s * Math.pow(t - 1, 2);
  // Sets an inline style only when its value changed (most frames, nothing does).
  const set = (el, k, v) => { v = String(v); const c = el._hl || (el._hl = {}); if (c[k] !== v) { c[k] = v; el.style[k] = v; } };
  // The cursor shape points up-left (-135°); this turns it to face an angle.
  const FACE = 135;

  // Seeded random numbers, so a replay looks exactly the same.
  function rng(seed) { let s = seed >>> 0; return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296); }

  const CSS = `
  .hl-root{position:absolute;inset:0;pointer-events:none;overflow:hidden;z-index:45;font:500 13px/1.3 -apple-system,system-ui,sans-serif}
  .hl-h{position:absolute;left:0;top:0;width:0;height:0;will-change:transform}
  .hl-tri{position:absolute;left:0;top:0;width:29px;height:29px;margin:-5.5px 0 0 -5.5px;transform-origin:5.5px 5.5px;will-change:transform;overflow:visible}
  .hl-tri path{stroke-width:4;stroke-linejoin:round}
  .hl-ring{position:absolute;left:0;top:0;width:44px;height:44px;margin:-22px 0 0 -22px}
  .hl-ring svg{position:absolute;inset:0;width:44px;height:44px;overflow:visible}
  .hl-ring circle{fill:none;stroke-linecap:round}
  /* The working motions run on their own layers (the whole ring turns; the helper bobs), so the graphics
     chip just moves a finished picture: redrawing an SVG every frame cost a lot of CPU. */
  .hl-spin{position:absolute;inset:0;will-change:transform}
  .hl-spin.sweep{animation:hlSweep 2.6s linear infinite}
  @keyframes hlSweep{from{transform:rotate(0)}to{transform:rotate(360deg)}}
  .hl-bob{position:absolute;left:0;top:0;will-change:transform}
  .hl-bob.on{animation:hlBob 1.7s ease-in-out infinite}
  @keyframes hlBob{0%,70%,100%{transform:translate(0,0)}82%{transform:translate(-1.6px,-1px)}}
  /* Finished, waiting to tell you: a small hop now and then. */
  .hl-bob.hop{animation:hlHop 2.6s ease-in-out infinite}
  @keyframes hlHop{0%,62%,100%{transform:translate(0,0)}71%{transform:translate(0,-4.5px)}79%{transform:translate(0,0)}85%{transform:translate(0,-1.6px)}90%{transform:translate(0,0)}}
  .hl-badge{position:absolute;left:0;top:0;width:13px;height:13px;margin:-6.5px 0 0 -6.5px;border-radius:50%;color:#fff;
    font:800 8.5px/13px -apple-system,system-ui,sans-serif;text-align:center;box-shadow:0 1px 3px rgba(0,0,0,.35),0 0 0 1.5px rgba(20,20,24,.85);opacity:0;will-change:transform,opacity}
  @media (prefers-reduced-motion: reduce){.hl-spin.sweep,.hl-bob.on,.hl-bob.hop{animation:none}}
  .hl-bub{position:absolute;left:0;top:0;white-space:nowrap;padding:5px 10px;border-radius:11px;color:#fff;
    font:600 12.5px/1.25 -apple-system,system-ui,sans-serif;box-shadow:0 6px 18px rgba(0,0,0,.22),0 1px 2px rgba(0,0,0,.2);
    transform-origin:0 50%;opacity:0}
  .hl-chip{position:absolute;left:0;top:0;width:236px;padding:8px 11px 9px;border-radius:13px;box-sizing:border-box;
    background:rgba(30,30,35,.9);
    box-shadow:0 8px 26px rgba(0,0,0,.28),inset 0 0 0 .5px rgba(255,255,255,.12);color:rgba(255,255,255,.92);opacity:0;will-change:transform,opacity}
  .hl-chip .top{display:flex;align-items:center;gap:6px;font:650 12px/1.2 -apple-system,system-ui,sans-serif;letter-spacing:.01em}
  .hl-chip .dot{width:8px;height:8px;border-radius:50%;flex:none}
  .hl-chip .count{margin-left:auto;font:500 11px/1 -apple-system,system-ui,sans-serif;color:rgba(255,255,255,.5);font-variant-numeric:tabular-nums}
  .hl-chip .lines{position:relative;height:17px;margin-top:4px;overflow:hidden}
  .hl-chip .ln{position:absolute;left:0;right:0;top:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-size:12.5px;color:rgba(255,255,255,.78)}
  .hl-chip .check{display:inline-block;margin-right:4px}
  .hl-chip .elapsed{margin-left:auto;font:500 11px/1 -apple-system,system-ui,sans-serif;color:rgba(255,255,255,.45);font-variant-numeric:tabular-nums}
  .hl-chip .count+.elapsed{margin-left:8px}
  .hl-chip.open{background:rgb(30,30,35);box-shadow:0 14px 40px rgba(0,0,0,.4),inset 0 0 0 .5px rgba(255,255,255,.14)}
  .hl-chip .more{height:0;overflow:hidden}
  .hl-chip .more .in{padding-top:9px}
  .hl-chip .task{font:600 12.5px/1.35 -apple-system,system-ui,sans-serif;color:#fff;display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden}
  .hl-chip .folder{margin-top:3px;font-size:11.5px;color:rgba(255,255,255,.5)}
  .hl-chip .sum{margin-top:8px;font-size:12px;line-height:1.42;color:rgba(255,255,255,.84);display:-webkit-box;-webkit-line-clamp:8;-webkit-box-orient:vertical;overflow:hidden}
  .hl-chip .sum:empty{display:none}
  .hl-chip .list{margin:8px 0 0;padding:0;list-style:none;font-size:12px;line-height:1.45;color:rgba(255,255,255,.6)}
  .hl-chip .list li{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .hl-chip .list li.done{color:rgba(255,255,255,.42)} .hl-chip .list li.active{color:#fff}
  .hl-chip .list .mk{display:inline-block;width:15px}
  .hl-chip .sep{height:.5px;background:rgba(255,255,255,.12);margin:8px 0 0}
  .hl-chip .btns{display:flex;gap:6px;margin-top:9px}
  .hl-chip .btns button{flex:1;font:600 11.5px -apple-system,system-ui,sans-serif;color:rgba(255,255,255,.9);background:rgba(255,255,255,.1);
    border:0;border-radius:7px;padding:5px 0;cursor:pointer}
  .hl-chip .btns button:hover{background:rgba(255,255,255,.18)}
  .hl-chip .btns button.stop{color:#ff8a80} .hl-chip .btns button.stop.sure{background:#e5484d;color:#fff}
  .hl-chip .askq{margin-top:8px;padding:7px 9px;border-radius:8px;background:rgba(255,255,255,.07);font:500 11.5px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace;
    color:rgba(255,255,255,.9);word-break:break-word;display:-webkit-box;-webkit-line-clamp:4;-webkit-box-orient:vertical;overflow:hidden}
  .hl-chip .askq:empty,.hl-chip .btns.ask:not(.on){display:none}
  .hl-chip .btns.ask button.yes{color:#fff}
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
      hold: false,        // finished helpers wait at the edge until report(id), and merge on release(id)
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
      this.seq = 0;
      this.side = this.params.dock === 'left' ? 'left' : 'right';
      this.avoid = null; this.pointer = null; this.rectKey = '';
      this.rand = rng(7);
      this.lastBig = -9; this.lastMerge = -9;   // so two finishing at once don't celebrate (or merge) on top of each other
    }

    destroy() { this.el.remove(); }
    setParams(p) { Object.assign(this.params, p); }
    get W() { return this.el.clientWidth || innerWidth; }
    /** The window you're using (points, or null): in 'auto', helpers work at the edge with more room beside it. */
    setAvoid(r) { this.avoid = r && r.w > 0 ? r : null; }
    /** Where the pointer is (or null), to fade cards you pass over and open a helper you rest on. */
    setPointer(p) { this.pointer = p; }
    chooseSide() {
      const want = this.params.dock;
      if (want === 'left' || want === 'right') return want;
      const a = this.avoid, W = this.W;
      if (!a) return this.side || 'right';
      const roomR = W - (a.x + a.w), roomL = a.x, need = 300;
      const cur = this.side || 'right';
      // Stay put unless the other side is clearly better.
      if (cur === 'right' && roomR < need && roomL > roomR + 120) return 'left';
      if (cur === 'left' && roomL < need && roomR > roomL + 120) return 'right';
      return cur;
    }
    get H() { return this.el.clientHeight || innerHeight; }
    sound(name, o = {}) { this.opts.sound && this.opts.sound(name, o); }
    main() { return this.opts.main.pos(); }
    react(kind, data) { this.opts.main.react && this.opts.main.react(kind, data); }

    // ---------- the API ----------

    spawn(id, { name, color, task, note = 0, detail = '', folder = '' }) {
      const m = this.main();
      const h = {
        id, name, color, task, note, phase: 'wait', t: 0, seq: ++this.seq,
        x: m.x, y: m.y, vx: 0, vy: 0, rot: 0, vrot: 0, scale: 0, alpha: 0,
        slot: this.freeSlot(), line: '', prev: '', lineT: 0, prevT: 9, count: '', items: [],
        frac: 0, fracShown: 0, chip: 0, chipX: 0, bub: '', bubT: 0, bubA: 0, ringA: 0, mood: 'work', trail: [],
        nod: -1, spin: -1, droop: 0, ask: '', askDetail: '', parked: false, gotText: '', handT: 0, el: null,
        detail: detail || task, folder, born: this.time, history: [], open: 0, openT: 0, hoverT: 0, closeT: 0, fade: 1, sure: 0,
      };
      this.helpers.set(id, h);
      this.order[h.slot] = id;
      this.build(h);
      this.nextBud();
      return h;
    }

    // Hand-offs happen one at a time: the next waiting helper buds when the stage is free.
    nextBud() {
      const all = [...this.helpers.values()];
      if (all.some(o => o.phase === 'bud' || o.phase === 'handoff')) return;
      const h = all.filter(o => o.phase === 'wait').sort((a, b) => a.seq - b.seq)[0];
      if (!h) return;
      const m = this.main();
      h.phase = 'bud'; h.t = 0; h.x = m.x; h.y = m.y; h.alpha = 1;
      this.react('bud', { id: h.id, x: m.x, y: m.y });
      this.sound('spawn', { x: m.x, note: h.note });
      this.burst(m.x + 8, m.y + 8, h.color, 7, 70);
    }

    step(id, text) {
      const h = this.helpers.get(id); if (!h || !text || text === h.line) return;
      h.prev = h.line; h.prevT = 0; h.line = text; h.lineT = 0;
      h.history.push(text); if (h.history.length > 30) h.history.shift();
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

    // One question at a time: the others keep working, with a pulsing ring, until it's their turn.
    // `detail`: exactly what it wants to do (the command), shown on its card.
    // `kind`: 'permission' (its card offers Allow / Don't allow) or 'question' (You choose / Skip).
    raiseHand(id, question, detail = '', kind = 'permission') {
      const h = this.helpers.get(id); if (!h) return;
      h.ask = question; h.askDetail = detail || question; h.askKind = kind; h.askSeq = ++this.seq; h.parked = false;
      this.nextAsk();
    }
    nextAsk() {
      const all = [...this.helpers.values()];
      if (all.some(o => o.phase === 'asking' || o.phase === 'thanks' || (o.phase === 'fly' && o.fly.kind === 'out'))) return;
      // Working at the edge, or still on its way there (it turns around instead of landing first).
      const free = o => o.phase === 'dock' || (o.phase === 'fly' && o.fly.kind === 'dock' && !o.finished && !o.pendingDone);
      const h = all.filter(o => o.ask && !o.parked && free(o)).sort((a, b) => a.askSeq - b.askSeq)[0];
      if (h) this.go(h, 'out', this.askSpot(h));
    }

    /** Answered (by voice or its card's buttons). `next`: another question it has, asked right away. */
    resolveHand(id, ok, next = '', nextDetail = '', nextKind = 'permission') {
      const h = this.helpers.get(id); if (!h || !h.ask) return;
      this.sound('ack', { x: h.x, note: h.note });
      h.nod = 0;
      if (h.phase === 'asking' && next) {   // stays next to you with its next question
        h.ask = next; h.askDetail = nextDetail || next; h.askKind = nextKind; h.bub = next; h.bubT = 0; h.t = 0;
        this.react('ask', { id: h.id, name: h.name, text: next });
        return;
      }
      if (h.phase === 'asking') {
        h.phase = 'thanks'; h.t = 0; h.ask = ''; h.bub = ok ? 'Thanks!' : 'Okay, skipping it'; h.bubT = 0;
      } else {   // answered from its card at the edge
        h.ask = ''; h.gotUntil = this.time + 2; h.gotText = ok ? '✓ Thanks' : 'Okay, skipping it'; h.lineT = 0;
      }
      if (next) this.raiseHand(id, next, nextDetail, nextKind);
      h.parked = false;
    }
    /** Not answered for a while: it goes back to work at the edge with its hand still up (a "?" on it),
     *  and the next helper with a question gets its turn. Answer it later from its card or by name. */
    park(id) {
      const h = this.helpers.get(id); if (!h || !h.ask) return;
      h.parked = true;
      if (h.phase === 'asking' || (h.phase === 'fly' && h.fly.kind === 'out')) { h.bub = ''; this.go(h, 'dock', this.slotPos(h)); }
    }

    done(id, { ok = true, summary = '' } = {}) {
      const h = this.helpers.get(id); if (!h) return;
      // Finished before it reached the edge, or while asking: it celebrates once it's back there.
      if (h.phase !== 'dock') { h.pendingDone = { ok, summary }; return; }
      // Another one just finished: celebrate a moment later, so the sounds and sparkles don't land together.
      if (this.time - this.lastBig < .45) { h.pendingDone = { ok, summary }; return; }
      this.lastBig = this.time;
      h.ask = ''; h.finished = true; h.endAt = this.time;
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

    /** (hold) The app is about to tell you what it did: it flies to the main buddy and waits there. */
    report(id) {
      const h = this.helpers.get(id); if (!h || (!h.finished && !h.pendingDone)) return;
      h.wantReport = true;
      if (h.phase === 'ready') this.toReport(h);
    }
    /** (hold) Done telling you: it merges into the main buddy (one at a time). */
    release(id) {
      const h = this.helpers.get(id); if (!h || (!h.finished && !h.pendingDone)) return;
      h.release = true; this.report(id);
    }
    afterDone(h) {
      if (!this.params.hold || h.wantReport) { this.toReport(h); return; }
      h.phase = 'ready'; h.t = 0;
      // Its card now shows what it did, in short.
      const short = HelperLayer.short(h.summary);
      if (short) { h.prev = h.line; h.prevT = 0; h.line = short; h.lineT = 0; }
    }
    toReport(h) { h.reportSeq = ++this.seq; this.go(h, 'report', this.reportSpot(h)); }
    /** The first sentence of a summary, short enough for one line. */
    static short(s) {
      s = String(s || '').replace(/[*_`#>]/g, '').replace(/\s+/g, ' ').trim();
      const m = s.match(/^.{12,}?[.!?](\s|$)/);
      return (m ? m[0] : s).trim();
    }

    /** You're holding the talk keys while pointing at it: it perks up and listens (its card opens). */
    listen(id, on) {
      const h = this.helpers.get(id); if (!h) return;
      h.listening = !!on;   // its card opens and its line says "Listening…"
    }
    /** It heard you: 'message' (a follow-up: "Got it!" and a nod) or 'status' (a nod while the buddy answers). */
    heard(id, kind) {
      const h = this.helpers.get(id); if (!h) return;
      h.listening = false;
      h.nod = 0;
      if (kind === 'message') { h.gotUntil = this.time + 2; this.sound('ack', { x: h.x, note: h.note }); }
    }
    /** The helper the pointer is on (or on its card), if any: you're talking to it while you hold the keys. */
    pointedId() {
      const p = this.pointer; if (!p) return null;
      let best = null, bestD = 1e9;
      for (const h of this.helpers.values()) {
        if (!['dock', 'ready', 'asking', 'thanks', 'report'].includes(h.phase) && !h.listening) continue;
        const d = Math.hypot(p.x - (h.x + 8 * h.scale), p.y - (h.y + 8 * h.scale));
        let hit = d < 30;
        if (!hit && (h.phase === 'dock' || h.phase === 'ready') && h.chip > .5) {
          const [x, y, w, ht] = this.cardRect(h);
          hit = p.x >= x && p.x <= x + w && p.y >= y && p.y <= y + ht;
        }
        if (hit && d < bestD) { best = h.id; bestD = d; }
      }
      return best;
    }

    get count() { return this.helpers.size; }
    /** Something is moving and needs smooth frames (otherwise a few frames a second are enough). */
    get busy() {
      if (this.parts.length) return true;
      if (this.chooseSide() !== this.side) return true;   // about to move to the other edge
      for (const h of this.helpers.values()) {
        if (h.hoverT > 0 || (h.open > .5 && h.closeT > 0)) return true;   // a card is about to open or close
        if ((h.phase !== 'dock' && h.phase !== 'ready') || (h.ask && !h.parked) || h.listening || h.gotUntil) return true;
        if (h.lineT < 2 || h.prevT < .4 || h.bubA > .01) return true;
        if (Math.abs(h.fracShown - h.frac) > .002 || (h.open > .001 && h.open < .999) || Math.abs(h.chip - 1) > .002) return true;
        if (Math.abs(h.fade - 1) > .003 && Math.abs(h.fade - .14) > .003) return true;
        if (Math.hypot(h.vx, h.vy) > 2 || h.nod >= 0 || h.spin >= 0 || h.squash >= 0 || Math.abs(h.vrot) > 1) return true;
      }
      return false;
    }
    pos(id) { const h = this.helpers.get(id); return h ? { x: h.x, y: h.y } : null; }

    // ---------- layout ----------

    freeSlot() { let i = 0; while (this.order[i] !== undefined) i++; return i; }
    slotPos(h) {
      const right = this.side !== 'left';
      return { x: right ? this.W - 34 : 34, y: 92 + h.slot * 66 };
    }
    askSpot(h) {
      const m = this.main(), right = this.side !== 'left';
      return { x: m.x + (right ? 60 : -60), y: m.y + 2 };
    }
    // Where a new helper buds: above the main buddy, toward the edge it will fly to.
    budDir() { return { x: this.side === 'left' ? -26 : 34, y: -34 }; }
    // Reporting back: clear of the main buddy's speech bubble (below it),
    // on the other side from where helpers bud, so a new hand-off and a report never collide. The first in line
    // reports; the others wait behind it, further out.
    reportSpot(h) {
      const m = this.main(), s = this.side === 'left' ? 1 : -1;
      const i = h ? this.reportIndex(h) : 0;
      return { x: m.x + s * (30 + i * 30), y: m.y - 34 - i * 20 };
    }
    reportIndex(h) {
      const line = [...this.helpers.values()].filter(o => o.reportSeq).sort((a, b) => a.reportSeq - b.reportSeq);
      return Math.max(0, line.indexOf(h));
    }

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
      // Move to the other edge when the window you're using needs this one (helpers fly over).
      const side = this.chooseSide();
      if (side !== this.side) {
        this.side = side;
        for (const h of this.helpers.values()) if (h.phase === 'dock' || h.phase === 'ready') this.go(h, 'dock', this.slotPos(h));
      }
      for (const h of [...this.helpers.values()]) {
        h.t += dt; h.lineT += dt; h.prevT += dt; h.bubT += dt;
        if (h.gotUntil && this.time > h.gotUntil) { h.gotUntil = 0; h.gotText = ''; h.lineT = 0; }
        const m = this.main();
        let tx = h.x, ty = h.y, follow = true, face = 0, targetScale = P.size;

        switch (h.phase) {
          case 'wait': {   // inside the main buddy until the stage is free
            h.x = m.x; h.y = m.y; h.scale = 0; h.alpha = 0; follow = false;
            break;
          }
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
            const to = f.kind === 'dock' ? this.slotPos(h) : f.kind === 'out' ? this.askSpot(h) : f.kind === 'report' ? this.reportSpot(h) : f.to;
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
              if (f.kind === 'dock') {
                h.phase = h.finished ? 'ready' : 'dock'; h.t = 0; this.sound('land', { x: h.x, note: h.note }); h.squash = 0;
                if (h.pendingDone) { const d = h.pendingDone; h.pendingDone = null; this.done(h.id, d); }
              }
              else if (f.kind === 'out') { h.phase = 'asking'; h.t = 0; h.bub = h.ask; h.bubT = 0; this.sound('hand', { x: h.x, note: h.note }); this.react('ask', { id: h.id, name: h.name, text: h.ask }); }
              else if (f.kind === 'report') { h.phase = 'report'; h.t = 0; h.reported = false; }
            }
            break;
          }
          case 'dock': {   // working: a soft "typing" tap toward its card
            const s = this.slotPos(h); tx = s.x; ty = s.y;
            if (h.ask && !h.parked) targetScale = P.size * (1 + .08 * Math.sin(h.t * 6));   // has a question, waiting its turn
            if (h.pendingDone && this.time - this.lastBig >= .45) { const d = h.pendingDone; h.pendingDone = null; this.done(h.id, d); }
            break;
          }
          case 'ready': {   // finished: waits at the edge (with a badge) until you're free to hear it
            const s = this.slotPos(h); tx = s.x; ty = s.y + (h.ok === false ? 4 : 0);
            if (h.wantReport) this.toReport(h);
            break;
          }
          case 'asking': {   // hopping gently next to you until you answer
            if (h.pendingDone) { h.phase = 'thanks'; h.t = .4; h.ask = ''; h.bub = ''; break; }   // it finished anyway
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
            if (h.t > 1.05) this.afterDone(h);
            break;
          }
          case 'droop': {
            const s = this.slotPos(h); tx = s.x; ty = s.y + Math.min(4, h.t * 10);
            h.droop = lerp(h.droop, 22, 1 - Math.exp(-dt * 6));
            if (h.t > 1.1) this.afterDone(h);
            break;
          }
          case 'report': {   // next to the main buddy while it tells you (or waiting its turn behind)
            const r = this.reportSpot(h); tx = r.x; ty = r.y + Math.sin(h.t * 4) * 1;
            face = Math.atan2(m.y - h.y, m.x - h.x) * 180 / Math.PI + FACE;
            if (this.reportIndex(h) > 0) { h.t = 0; break; }
            if (!h.reported) {
              h.reported = true; h.t = 0;
              // Held: until the app says it's done talking (with a safety limit). Otherwise: about as long as reading it.
              h.reportFor = P.hold ? 45 : clamp(1.6 + (h.summary || '').length * .045, 2.4, 6.5);
              this.react('report', { id: h.id, name: h.name, color: h.color, ok: h.ok, summary: h.summary });
            }
            const leave = h.t > h.reportFor || (P.hold && h.release && h.t > .6);
            if (leave && this.time - this.lastMerge > .32) { this.lastMerge = this.time; h.phase = 'merge'; h.t = 0; h.reportSeq = 0; this.sound('merge', { x: m.x, note: h.note }); this.react('absorb', { id: h.id }); }
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

        if (h.listening && (h.phase === 'dock' || h.phase === 'ready')) targetScale *= 1.18;
        if (follow) {   // a spring toward the target: a step behind, a little overshoot
          h.vx += ((tx - h.x) * k - h.vx * c) * dt; h.vy += ((ty - h.y) * k - h.vy * c) * dt;
          h.x += h.vx * dt; h.y += h.vy * dt;
          h.scale = lerp(h.scale, targetScale, 1 - Math.exp(-dt * 12)); h.alpha = lerp(h.alpha, 1, 1 - Math.exp(-dt * 10));
        }
        // Turning, on its own spring (the shortest way around).
        let want = face + (h.phase === 'droop' || ((h.phase === 'report' || h.phase === 'ready') && h.ok === false) ? h.droop : 0);
        let diff = ((want - h.rot) % 360 + 540) % 360 - 180;
        h.vrot += (diff * 140 - h.vrot * 18) * dt; h.rot += h.vrot * dt;
        if (h.nod >= 0) { h.nod += dt; if (h.nod > .5) h.nod = -1; }
        if (h.spin >= 0) { h.spin += dt; if (h.spin > .7) h.spin = -1; }
        if (h.squash !== undefined && h.squash >= 0) { h.squash += dt; if (h.squash > .3) h.squash = -1; }
        // Card: shown while it works at the edge.
        const showChip = ['dock', 'celebrate', 'droop', 'ready'].includes(h.phase) || (h.phase === 'fly' && h.fly.kind === 'dock' && h.fly.u > .93);
        const dimChip = ['asking', 'thanks'].includes(h.phase) || (h.phase === 'fly' && h.fly.kind === 'out');
        h.chip = lerp(h.chip, showChip ? 1 : dimChip ? .55 : 0, 1 - Math.exp(-dt * 9));
        h.chipX = lerp(h.chipX, showChip || dimChip ? 0 : 1, 1 - Math.exp(-dt * 9));
        h.fracShown = lerp(h.fracShown, h.frac, 1 - Math.exp(-dt * 6));
        this.hover(h, dt);
        // Fades, advanced with time (not per drawn frame) so a scrubbed timeline looks the same.
        const working = ['dock', 'celebrate', 'droop', 'ready'].includes(h.phase);
        h.badgeA = lerp(h.badgeA || 0, h.phase === 'ready' || (h.ask && h.phase === 'dock') ? 1 : 0, 1 - Math.exp(-dt * 10));
        h.ringA = lerp(h.ringA, working ? 1 : 0, 1 - Math.exp(-dt * 10));
        h.bubA = lerp(h.bubA, h.bub ? 1 : 0, 1 - Math.exp(-dt * 16));
        for (const p of h.trail) p.a -= dt * 4;
      }
      // Helpers near the main buddy never sit on top of each other: a gentle push apart.
      const near = [...this.helpers.values()].filter(h => !['wait', 'bud', 'fly', 'merge', 'dock', 'celebrate', 'droop', 'ready'].includes(h.phase));
      for (let i = 0; i < near.length; i++) for (let j = i + 1; j < near.length; j++) {
        const a = near[i], b = near[j], dx = b.x - a.x, dy = b.y - a.y, d = Math.hypot(dx, dy) || .01, min = 30;
        if (d < min) { const push = (min - d) / 2 / d; a.x -= dx * push; a.y -= dy * push; b.x += dx * push; b.y += dy * push; }
      }
      this.nextBud(); this.nextAsk();
      // Open cards take clicks: tell the app where they are.
      const rects = [...this.helpers.values()].filter(h => h.open > .5).map(h => this.cardRect(h).map(Math.round));
      const key = JSON.stringify(rects);
      if (key !== this.rectKey) { this.rectKey = key; this.opts.onRects && this.opts.onRects(rects); }
      // Particles
      for (const p of this.parts) {
        p.life += dt; p.vx *= Math.exp(-dt * 3.2); p.vy = p.vy * Math.exp(-dt * 3.2) + 40 * dt;
        p.x += p.vx * dt; p.y += p.vy * dt;
      }
      this.parts = this.parts.filter(p => p.life < p.max);
    }

    // The card's rectangle [x, y, w, h] in points.
    cardRect(h) {
      const s = this.slotPos(h), cw = 236, right = this.side !== 'left';
      return [right ? s.x - 22 - cw : s.x + 30, s.y - 15, cw, h.cardH || 52];
    }

    // Passing over a card fades it (so you can see what's under it); resting on the helper opens its full card.
    hover(h, dt) {
      const p = this.pointer, working = h.phase === 'dock' || h.phase === 'ready';
      let fadeTo = 1, openTo = h.open > .5 ? 1 : 0;
      if (!working) openTo = 0;
      else if (p) {
        const [x, y, w, ht] = this.cardRect(h);
        const cx = h.x + 8 * h.scale, cy = h.y + 8 * h.scale;
        const onHelper = Math.hypot(p.x - cx, p.y - cy) < 22;
        const inCard = p.x >= x - 8 && p.x <= x + w + 8 && p.y >= y - 8 && p.y <= y + ht + 8;
        const nearCard = p.x >= x - 28 && p.x <= x + w + 28 && p.y >= y - 24 && p.y <= y + ht + 24;
        if (h.open > .5) {
          if (onHelper || inCard) h.closeT = 0;
          else if ((h.closeT += dt) > .35) openTo = 0;
        } else if (onHelper) {
          if ((h.hoverT += dt) > .3) { openTo = 1; h.closeT = 0; }
        } else {
          h.hoverT = 0;
          if (nearCard) fadeTo = .14;
        }
      } else { h.hoverT = 0; if (h.open > .5 && (h.closeT += dt) > .35) openTo = 0; }
      if (h.listening) { openTo = 1; fadeTo = 1; h.closeT = 0; }
      if (!openTo) h.sure = 0;
      h.open = lerp(h.open, openTo, 1 - Math.exp(-dt * 14));
      if (Math.abs(h.open - openTo) < .002) h.open = openTo;
      h.fade = lerp(h.fade, fadeTo, 1 - Math.exp(-dt * 12));
      if (h.sure > 0 && (h.sure -= dt) <= 0) h.sure = 0;
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
        `<div class="hl-ring"><div class="hl-spin"><svg viewBox="-22 -22 44 44"><circle class="bg" r="16" stroke-width="2"/><circle class="fg" r="16" stroke-width="2.4" transform="rotate(-90)"/></svg></div></div>` +
        `<div class="hl-bob"><svg class="hl-tri" viewBox="-3 -3 26 26"><path d="M2,2 L17,8 L8,17 Z"/></svg></div>` +
        `<div class="hl-badge"></div><div class="hl-bub"></div>`;
      const path = root.querySelector('path');
      path.style.fill = h.color; path.style.stroke = h.color;
      path.style.filter = `drop-shadow(0 0 5px ${h.color}bb) drop-shadow(0 2px 3px rgba(0,0,0,.25))`;
      root.querySelector('.bg').style.stroke = h.color + '33';
      root.querySelector('.fg').style.stroke = h.color;
      const bub = root.querySelector('.hl-bub'); bub.style.background = h.color;
      const chip = document.createElement('div'); chip.className = 'hl-chip';
      chip.innerHTML = `<div class="top"><span class="dot"></span><span class="name"></span><span class="count"></span><span class="elapsed"></span></div>` +
        `<div class="lines"><div class="ln prev"></div><div class="ln cur"></div></div>` +
        `<div class="more"><div class="in"><div class="task"></div><div class="folder"></div><div class="askq"></div><div class="btns ask"><button class="yes" data-a="allow">Allow</button><button data-a="deny">Don’t allow</button></div>` +
        `<div class="sum"></div><ul class="list"></ul><div class="sep"></div>` +
        `<div class="btns"><button class="stop">Stop</button><button data-a="log">Log</button><button data-a="folder">Folder</button></div></div></div>`;
      chip.querySelector('.task').textContent = h.detail;
      chip.querySelector('.folder').textContent = h.folder ? 'in ' + h.folder : '';
      // Stop asks once more ("Stop Mint?") before it stops anything.
      chip.querySelector('.stop').onclick = () => {
        if (h.sure > 0) { h.sure = 0; this.opts.onAction && this.opts.onAction(h.id, 'stop'); }
        else h.sure = 3;
      };
      chip.querySelectorAll('[data-a]').forEach(b => b.onclick = () => this.opts.onAction && this.opts.onAction(h.id, b.dataset.a));
      chip.querySelector('.dot').style.background = h.color;
      chip.querySelector('.dot').style.boxShadow = `0 0 6px ${h.color}`;
      const name = chip.querySelector('.name'); name.textContent = h.name; name.style.color = h.color;
      chip.querySelector('.btns.ask .yes').style.background = h.color;
      const trail = [];
      for (let i = 0; i < 9; i++) { const t = document.createElement('div'); t.className = 'hl-trail'; t.style.background = h.color; this.el.appendChild(t); trail.push(t); }
      this.el.appendChild(chip); this.el.appendChild(root);
      h.el = { root, tri: root.querySelector('.hl-tri'), ring: root.querySelector('.hl-ring'), fg: root.querySelector('.fg'), bub, chip, trail,
        spin: root.querySelector('.hl-spin'), bob: root.querySelector('.hl-bob'),
        count: chip.querySelector('.count'), prev: chip.querySelector('.prev'), cur: chip.querySelector('.cur'), cache: {},
        elapsed: chip.querySelector('.elapsed'), more: chip.querySelector('.more'), inner: chip.querySelector('.more .in'),
        list: chip.querySelector('.list'), stop: chip.querySelector('.stop'), sum: chip.querySelector('.sum'), badge: root.querySelector('.hl-badge'),
        askq: chip.querySelector('.askq'), abtns: chip.querySelector('.btns.ask') };
    }

    render() {
      const P = this.params, right = this.side !== 'left';
      for (const h of this.helpers.values()) {
        const e = h.el, C = e.cache;
        let sx = h.scale, sy = h.scale, rot = h.rot, dy = 0;
        if (h.nod >= 0) { const p = h.nod / .5; dy += Math.sin(p * Math.PI * 2) * 3 * (1 - p); }
        if (h.spin >= 0) { const p = easeInOut(h.spin / .7); rot += p * 360; sx *= 1 + Math.sin(p * Math.PI) * .3; sy = sx; }
        if (h.squash >= 0) { const p = h.squash / .3; sx *= 1 + Math.sin(p * Math.PI) * .18; sy *= 1 - Math.sin(p * Math.PI) * .14; }
        set(e.root, 'transform', `translate(${h.x.toFixed(1)}px,${(h.y + dy).toFixed(1)}px)`);
        set(e.tri, 'transform', `rotate(${rot.toFixed(1)}deg) scale(${sx.toFixed(3)},${sy.toFixed(3)})`);
        // Progress ring around it while it works.
        set(e.ring, 'opacity', h.ringA.toFixed(3));
        set(e.ring, 'transform', `translate(${(8.2 * h.scale).toFixed(1)}px,${(8.2 * h.scale).toFixed(1)}px) scale(${(.6 + .4 * h.scale / P.size).toFixed(3)})`);
        const L = TAU * 16;
        if (h.items.length || h.phase === 'celebrate' || h.finished) {
          set(e.fg, 'strokeDasharray', h.fracShown < .005 ? `0 ${L.toFixed(1)}` : `${(L * h.fracShown).toFixed(1)} ${L.toFixed(1)}`);
          set(e.fg, 'opacity', h.fracShown < .005 ? 0 : 1);
          e.fg.setAttribute('transform', 'rotate(-90)');
        } else {   // no to-do list: a slow, quiet sweep (CSS)
          set(e.fg, 'strokeDasharray', `${(L * .22).toFixed(1)} ${L.toFixed(1)}`);
          set(e.fg, 'opacity', 1);
        }
        if (h.finished && h.ok && !h.items.length) h.frac = 1;
        const sweep = !h.items.length && h.phase !== 'celebrate' && !h.finished;
        if (C.sweep !== sweep) { e.spin.classList.toggle('sweep', sweep); C.sweep = sweep; }
        const bob = h.phase === 'dock' && !P.calm, hop = h.phase === 'ready' && !P.calm;
        if (C.bob !== bob) { e.bob.classList.toggle('on', bob); C.bob = bob; }
        if (C.hop !== hop) { e.bob.classList.toggle('hop', hop); C.hop = hop; }
        // Its badge while it waits to tell you: a check (or "!" if it couldn't finish).
        // (A "?" while it waits for your answer.)
        const badge = h.ask ? '?' : h.ok === false ? '!' : '✓';
        if (C.badge !== badge) { e.badge.textContent = badge; set(e.badge, 'background', badge === '!' ? '#8b8b93' : h.color); C.badge = badge; }
        set(e.badge, 'opacity', (h.badgeA || 0).toFixed(3));
        set(e.badge, 'transform', `translate(${(17 * h.scale).toFixed(1)}px,${(19 * h.scale).toFixed(1)}px) scale(${(.4 + .6 * easeOutBack(clamp(h.badgeA || 0, 0, 1), 2.4)).toFixed(3)})`);
        set(e.fg, 'stroke', h.phase === 'droop' || (h.ok === false) ? '#8b8b93' : h.color);
        // Its speech bubble ("On it!", a question).
        const bubOn = !!h.bub;
        if (C.bubText !== h.bub && h.bub) { e.bub.textContent = h.bub; C.bubText = h.bub; }
        const bs = bubOn ? easeOutBack(clamp(h.bubT / .3, 0, 1), 2) : 1;
        if (C.bubW === undefined || C.bubWText !== C.bubText) { C.bubW = e.bub.offsetWidth || 60; C.bubWText = C.bubText; }
        let toLeft = !right;
        if (h.x + 18 + C.bubW > this.W - 8) toLeft = true;
        if (h.x - 18 - C.bubW < 8) toLeft = false;
        const bx = toLeft ? -18 - C.bubW : 18;
        set(e.bub, 'transformOrigin', toLeft ? '100% 50%' : '0 50%');
        set(e.bub, 'transform', `translate(${bx}px,-30px) scale(${(.6 + .4 * bs).toFixed(3)})`);
        set(e.bub, 'opacity', h.bubA.toFixed(3));
        // The card at the edge.
        const s = this.slotPos(h);
        // It grows out of the helper, toward the middle of the screen.
        const cw = 236, cx = right ? s.x - 22 - cw + h.chipX * 10 : s.x + 30 - h.chipX * 10;
        set(e.chip, 'transformOrigin', right ? '100% 50%' : '0 50%');
        set(e.chip, 'transform', `translate(${cx.toFixed(1)}px,${(s.y - 15).toFixed(1)}px) scale(${(.86 + .14 * h.chip + .02 * h.open).toFixed(3)})`);
        set(e.chip, 'opacity', (h.chip * lerp(h.fade, 1, h.open)).toFixed(3));
        set(e.root, 'opacity', (h.alpha * lerp(.35 + .65 * h.fade, 1, h.open)).toFixed(3));
        // The full card: what it was asked, where, its to-do list or recent steps, and buttons.
        const open = h.open > .01;
        if (C.open !== open) { e.chip.classList.toggle('open', open); C.open = open; }
        set(e.chip, 'zIndex', open ? 2 : '');
        set(e.chip, 'pointerEvents', h.open > .5 ? 'auto' : 'none');
        const secs = Math.max(0, Math.floor((h.endAt ?? this.time) - h.born));
        const el = secs < 60 ? `${secs}s` : `${Math.floor(secs / 60)} min`;
        if (C.el !== el) { e.elapsed.textContent = el; C.el = el; }
        if (open) {
          const rows = h.items.length
            ? h.items.slice(0, 6).map(i => [i.state, i.state === 'done' ? '✓' : i.state === 'active' ? '●' : '○', i.text])
            : h.history.slice(-5, -1).map(t => ['done', '·', t]);
          const key = JSON.stringify(rows);
          if (C.rows !== key) {
            C.rows = key;
            e.list.innerHTML = '';
            for (const [st, mk, text] of rows) {
              const li = document.createElement('li'); li.className = st;
              const m = document.createElement('span'); m.className = 'mk'; m.textContent = mk;
              if (st === 'active') set(m, 'color', h.color);
              li.append(m, document.createTextNode(text)); e.list.appendChild(li);
            }
          }
          // Finished: what it did, in full (and nothing left to stop).
          const askText = h.ask ? h.askDetail : '';
          if (C.askq !== askText) { e.askq.textContent = askText; e.abtns.classList.toggle('on', !!askText); C.askq = askText; }
          if (C.askKind !== h.askKind) {
            const q = h.askKind === 'question';
            e.abtns.children[0].textContent = q ? 'You choose' : 'Allow';
            e.abtns.children[1].textContent = q ? 'Skip' : 'Don’t allow';
            C.askKind = h.askKind;
          }
          if (C.fin !== !!h.finished) { C.fin = !!h.finished; e.sum.textContent = h.finished ? h.summary : ''; set(e.stop, 'display', h.finished ? 'none' : ''); }
          const label = h.sure > 0 ? `Stop ${h.name}?` : 'Stop';
          if (C.stop !== label) { e.stop.textContent = label; e.stop.classList.toggle('sure', h.sure > 0); C.stop = label; }
        }
        const full = open ? e.inner.offsetHeight : 0;
        set(e.more, 'height', (full * easeInOut(clamp(h.open, 0, 1))).toFixed(1) + 'px');
        if (open || C.cardH === undefined) C.cardH = e.chip.offsetHeight || 52;
        h.cardH = C.cardH;
        if (C.count !== h.count) { e.count.textContent = h.count; C.count = h.count; }
        // Progress text types in; the old line slides up and fades.
        const n = Math.floor(h.lineT * 45 * P.typing);
        const shown = h.line.slice(0, Math.max(0, n));
        // Talking to it: its line says it's listening, then that it got your message.
        const said = h.listening ? 'Listening…' : h.gotUntil ? (h.gotText || '✓ Got it') : h.ask ? 'Waiting for your OK' : '';
        const cur = said || (h.finished && h.ok ? '✓ ' : '') + shown;
        if (C.cur !== cur) { e.cur.textContent = cur; C.cur = cur; }
        if (C.prev !== h.prev) { e.prev.textContent = h.prev; C.prev = h.prev; }
        const pu = clamp(h.prevT / .28, 0, 1);
        set(e.prev, 'transform', `translateY(${(-14 * easeOut(pu)).toFixed(1)}px)`); set(e.prev, 'opacity', (1 - pu).toFixed(3));
        const cu = clamp(h.lineT / .28, 0, 1);
        set(e.cur, 'transform', `translateY(${(10 * (1 - easeOut(cu))).toFixed(1)}px)`); set(e.cur, 'opacity', cu.toFixed(3));
        set(e.cur, 'color', h.phase === 'celebrate' || said ? h.color : '');
        // Trail
        e.trail.forEach((t, i) => {
          const p = h.trail[i];
          if (!p || p.a <= 0) { set(t, 'opacity', 0); return; }
          const k = 1 - i / 9;
          set(t, 'transform', `translate(${p.x.toFixed(1)}px,${p.y.toFixed(1)}px) scale(${(k * h.scale / P.size).toFixed(3)})`);
          set(t, 'opacity', (p.a * k * .55).toFixed(3));
        });
      }
      // Particles, from a pool of divs.
      while (this.pool.length < this.parts.length) { const d = document.createElement('div'); d.className = 'hl-p'; this.el.appendChild(d); this.pool.push(d); }
      this.pool.forEach((d, i) => {
        const p = this.parts[i];
        if (!p) { set(d, 'opacity', '0'); return; }
        const u = p.life / p.max;
        const sz = p.size.toFixed(1) + 'px'; set(d, 'width', sz); set(d, 'height', sz);
        set(d, 'background', p.color); set(d, 'boxShadow', `0 0 6px ${p.color}`);
        set(d, 'transform', `translate(${(p.x - p.size / 2).toFixed(1)}px,${(p.y - p.size / 2).toFixed(1)}px) scale(${(1 - u * .6).toFixed(3)})`);
        set(d, 'opacity', (1 - u * u).toFixed(3));
      });
    }
  }

  global.HelperLayer = HelperLayer;
})(window);

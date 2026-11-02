// Connects the app to the helpers on screen (web/helpers.js) and their sounds (web/sounds.js).
// Adds to window.SB: helperSpawn, helperStep, helperChecklist, helperDone, helperReport, helperRelease, helperStop,
// helperSounds, helperPos.
// Tells the app how many helpers are on screen ({kind: 'helpers', count}), so the overlay stays up while they work.
(function () {
  const SB = window.SB;
  if (!SB || !window.HelperLayer) return;
  const sounds = new Sounds();
  let soundOn = true;
  const post = m => { try { window.webkit.messageHandlers.sb.postMessage(m); } catch (e) {} };

  const layer = new HelperLayer(document.body, {
    main: {
      pos: () => SB.buddyPos() || { x: innerWidth / 2, y: innerHeight / 2 },
      react: (kind, d) => SB.buddyReact(kind, d),
    },
    sound: (name, o) => {
      if (!soundOn) return;
      const W = innerWidth || 1;
      sounds.play(name, Object.assign({}, o, { x: o.x !== undefined ? o.x / W * 2 - 1 : 0, x2: o.x2 !== undefined ? o.x2 / W * 2 - 1 : undefined }));
    },
    // hold: a finished helper waits at the edge until the app is about to tell you (helperReport).
    params: { calm: matchMedia('(prefers-reduced-motion: reduce)').matches, dock: 'auto', hold: true },
    // An open card takes clicks: the app lets the mouse through to it there.
    onRects: rects => post({ kind: 'helperRects', rects }),
    onAction: (id, action) => post({ kind: 'helperAction', id: String(id), action }),
  });

  // Runs only while there are helpers. Smooth frames while something moves; when they're all just
  // working at the edge (their small motions are CSS), ten frames a second are plenty.
  let running = false, last = 0, lastCount = 0, idleTimer = 0, smooth = false;
  // Frame timing while something moves (for tests: SB.helperStats()).
  let stats = { frames: 0, gaps: [] };
  function frame(now) {
    idleTimer = 0;
    if (smooth) { stats.frames++; stats.gaps.push(now - last); }
    const dt = Math.min(1 / 30, (now - last) / 1000); last = now;
    layer.setPointer(SB.cursorPos ? SB.cursorPos() : null);
    layer.update(dt); layer.render();
    if (layer.count !== lastCount) { lastCount = layer.count; post({ kind: 'helpers', count: lastCount }); }
    if (!layer.count && !layer.parts.length) { running = false; return; }
    smooth = layer.busy;
    if (smooth) requestAnimationFrame(frame);
    else idleTimer = setTimeout(() => requestAnimationFrame(frame), 100);
  }
  function wake() {
    if (idleTimer) { clearTimeout(idleTimer); idleTimer = 0; requestAnimationFrame(frame); return; }
    if (!running) { running = true; last = performance.now(); requestAnimationFrame(frame); }
  }

  Object.assign(SB, {
    /** A helper starts: it buds off the buddy, gets its task and flies to the edge. `note`: its place in the name list. */
    helperSpawn(id, name, task, note, detail, folder) {
      id = String(id);
      layer.spawn(id, { name, color: HelperLayer.colors[name.split(' ')[0]] || '#34c98e', task, note: +note || 0, detail, folder });
      wake();
    },
    helperStep(id, text) { layer.step(String(id), text); wake(); },
    /** items: [{text, state: pending|active|done}] */
    helperChecklist(id, items) { layer.checklist(String(id), items || []); wake(); },
    helperDone(id, ok, summary) { layer.done(String(id), { ok: !!ok, summary: summary || '' }); wake(); },
    /** Poinky is about to say what these did: they fly to the buddy and wait there while it talks. */
    helperReport(ids) { (ids || []).forEach(id => layer.report(String(id))); wake(); },
    /** Poinky finished saying it (or was cut off): they merge into the buddy, one at a time. */
    helperRelease(ids) { (ids || []).forEach(id => layer.release(String(id))); wake(); },
    helperStop(id) { layer.stop(String(id)); wake(); },
    helperSounds(on, volume) {
      soundOn = !!on;
      sounds.params.master = Math.max(0, Math.min(1.2, +volume || 0)) * 1.1;
    },
    helperDock(side) { layer.setParams({ dock: side === 'left' || side === 'right' ? side : 'auto' }); },
    /** The window you're using (points), so helpers work at the edge with more room beside it. */
    helperAvoid(r) { layer.setAvoid(r); if (layer.chooseSide() !== layer.side) wake(); },
    helperPos(id) { return layer.pos(String(id)); },
    /** For tests: frame timing while helpers move, since the last call. */
    helperStats() {
      const g = stats.gaps.slice().sort((a, b) => a - b), n = g.length;
      const r = n ? { frames: n, avg: +(g.reduce((a, b) => a + b, 0) / n).toFixed(1), p95: +g[Math.floor(n * .95)].toFixed(1),
        max: +g[n - 1].toFixed(1), over25: g.filter(x => x > 25).length } : { frames: 0 };
      stats = { frames: 0, gaps: [] };
      return JSON.stringify(r);
    },
    /** For tests: "1:dock 2:fly>report …". */
    helperPhases() { return [...layer.helpers.values()].map(h => h.id + ':' + h.phase + (h.phase === 'fly' ? '>' + h.fly.kind : '')).join(' '); },
  });
})();

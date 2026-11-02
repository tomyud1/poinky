// Connects the app to the helpers on screen (web/helpers.js) and their sounds (web/sounds.js).
// Adds to window.SB: helperSpawn, helperStep, helperChecklist, helperDone, helperStop, helperSounds, helperPos.
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
    params: { calm: matchMedia('(prefers-reduced-motion: reduce)').matches, dock: 'auto' },
    // An open card takes clicks: the app lets the mouse through to it there.
    onRects: rects => post({ kind: 'helperRects', rects }),
    onAction: (id, action) => post({ kind: 'helperAction', id: String(id), action }),
  });

  // Runs only while there are helpers. Smooth frames while something moves; when they're all just
  // working at the edge (their small motions are CSS), ten frames a second are plenty.
  let running = false, last = 0, lastCount = 0, idleTimer = 0;
  function frame(now) {
    idleTimer = 0;
    const dt = Math.min(1 / 30, (now - last) / 1000); last = now;
    layer.setPointer(SB.cursorPos ? SB.cursorPos() : null);
    layer.update(dt); layer.render();
    if (layer.count !== lastCount) { lastCount = layer.count; post({ kind: 'helpers', count: lastCount }); }
    if (!layer.count && !layer.parts.length) { running = false; return; }
    if (layer.busy) requestAnimationFrame(frame);
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
    helperStop(id) { layer.stop(String(id)); wake(); },
    helperSounds(on, volume) {
      soundOn = !!on;
      sounds.params.master = Math.max(0, Math.min(1.2, +volume || 0)) * 1.1;
    },
    helperDock(side) { layer.setParams({ dock: side === 'left' || side === 'right' ? side : 'auto' }); },
    /** The window you're using (points), so helpers work at the edge with more room beside it. */
    helperAvoid(r) { layer.setAvoid(r); },
    helperPos(id) { return layer.pos(String(id)); },
  });
})();

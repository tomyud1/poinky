/* Poinky: a picture of something on paper (your work, from your iPhone, a drop, a paste, a recent file).
   A small card shows what Poinky got, with Retake / + Page / Check now, a short countdown before it's used,
   and the waiting and "no iPhone nearby" states. Pictures dropped on the paper or a card come in here too.
   The flow is native (CallController+Photo.swift); this page only shows and reports clicks:

   SB.workPhoto({state, title, text, thumbs:[dataURL], buttons:[{id,label,primary}], countdown:secs, icon})
     state: 'waiting' (taking it on the phone) · 'got' (what came) · 'confirm' (is this the one?) · 'ready'
            (goes with your next question) · 'error' · 'sent' (fades by itself)
   SB.workPhoto(null)    takes the card away
   Posts {kind:'workPhoto', action, x, y} (a button, with its center in screen points), 'hold' / 'resume'
   (the mouse rests on the card: the countdown waits), and 'drop' with {files:[{name, type, data}]}. */
(function () {
  const X = window.SBX, SB = window.SB;
  const css = document.createElement('style');
  css.textContent = `
    .card.shot{width:268px;border-radius:16px;overflow:hidden;background:rgba(250,250,252,.97);color:#1f2328;
      box-shadow:0 18px 48px rgba(0,0,0,.32),0 0 0 1px rgba(0,0,0,.07);font:13px/1.35 -apple-system,system-ui,sans-serif}
    .shot .sh-head{height:34px;display:flex;align-items:center;gap:7px;padding:0 40px 0 12px;cursor:grab;
      font:600 12.5px -apple-system,system-ui;color:#5d6470;background:rgba(0,0,0,.035);border-bottom:1px solid rgba(0,0,0,.06)}
    .shot .sh-head .x{top:3px;right:4px}
    .shot .sh-t{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    .shot .sh-body{padding:10px 12px 0;display:flex;gap:8px;justify-content:center;min-height:0}
    .shot .sh-body img{display:block;max-width:100%;max-height:200px;border-radius:7px;background:#e8e8ec;
      box-shadow:0 1px 4px rgba(0,0,0,.18);-webkit-user-drag:none;pointer-events:none;animation:sh-in .35s cubic-bezier(.2,.9,.3,1.15)}
    .shot .sh-body.many img{max-width:calc(50% - 4px);max-height:150px}
    .shot .sh-body .more{align-self:center;font:600 12px -apple-system,system-ui;color:#5d6470}
    .shot .sh-text{padding:9px 13px 0;color:#3b4048}
    .shot .sh-text:empty{display:none}
    .shot .sh-btns{display:flex;flex-wrap:wrap;gap:6px;padding:10px 12px 12px;justify-content:flex-end}
    .shot .sh-btns button{height:27px;border-radius:14px;border:0;padding:0 12px;cursor:pointer;white-space:nowrap;
      background:rgba(30,32,38,.08);color:#3b4048;font:600 12.5px -apple-system,system-ui;transition:background .15s,color .15s,transform .1s}
    .shot .sh-btns button:hover{background:rgba(30,32,38,.72);color:#fff}
    .shot .sh-btns button:active{transform:scale(.95)}
    .shot .sh-btns button.primary{background:#3b6ef6;color:#fff}
    .shot .sh-btns button.primary:hover{background:#2f5bd0}
    .shot .sh-bar{height:3px;background:rgba(59,110,246,.12)}
    .shot .sh-bar i{display:block;height:100%;width:100%;background:#3b6ef6;transform-origin:left}
    .shot .sh-bar.run i{animation:sh-count var(--secs,4s) linear forwards}
    .shot .sh-bar.held i{animation-play-state:paused}
    .shot .sh-bar[hidden]{display:none}
    /* Waiting for the phone: a phone outline with a soft ring going out of it. */
    .shot .phone{position:relative;width:46px;height:78px;margin:6px auto 2px;border:3px solid #3b6ef6;border-radius:11px;box-sizing:border-box}
    .shot .phone::after{content:'';position:absolute;left:50%;top:5px;width:12px;height:3px;margin-left:-6px;border-radius:2px;background:#3b6ef6}
    .shot .phone::before{content:'';position:absolute;inset:-10px;border-radius:18px;border:2px solid rgba(59,110,246,.5);animation:sh-ring 1.8s ease-out infinite}
    .shot.error .phone{border-color:#a0a6b0}.shot.error .phone::after{background:#a0a6b0}.shot.error .phone::before{display:none}
    .shot.sent{transition:opacity .5s .9s,transform .5s .9s;opacity:0;transform:scale(.94) translateY(-6px)}
    .shot .ok{font:600 13px -apple-system,system-ui;color:#2f9a58;text-align:center;padding:4px 0 10px}
    @keyframes sh-ring{from{transform:scale(.85);opacity:1}to{transform:scale(1.25);opacity:0}}
    @keyframes sh-count{from{transform:scaleX(1)}to{transform:scaleX(0)}}
    @keyframes sh-in{from{opacity:0;transform:scale(.92)}to{opacity:1;transform:none}}
    @media (prefers-reduced-motion: reduce){.shot .phone::before{animation:none;opacity:.5}.shot .sh-body img{animation:none}}
    /* A picture is being dragged over the overlay: what can take it says so. */
    body.photo-drop .card.lpaper, body.photo-drop .card.shot{box-shadow:0 0 0 3px #3b6ef6,0 18px 48px rgba(0,0,0,.32)}
  `;
  document.head.appendChild(css);

  let card = null, sentTimer = null;
  const post = (action, extra) => X.post(Object.assign({ kind: 'workPhoto', action }, extra || {}));

  function place(c) {
    if (c.dataset.moved) return;
    const w = 268, paper = document.querySelector('.card.lpaper:not(.leaving)');
    let x = innerWidth - w - 28, y = 86;
    if (paper) {
      const r = paper.getBoundingClientRect();
      if (r.left - w - 18 >= 8) x = r.left - w - 18; else if (r.right + 18 + w <= innerWidth - 8) x = r.right + 18;
      y = Math.max(46, Math.min(innerHeight - 330, r.top + 40));
    }
    c.style.left = Math.round(x) + 'px'; c.style.top = Math.round(y) + 'px';
  }

  SB.workPhoto = o => {
    clearTimeout(sentTimer);
    if (!o) { if (card) X.removeCard(card); card = null; return; }
    let fresh = false;
    if (!card || !card.isConnected || card.classList.contains('leaving')) {
      card = document.createElement('div');
      card.className = 'card shot'; card.dataset.id = 'workphoto'; card.dataset.type = 'photo of your work'; card.dataset.label = '';
      card.innerHTML = '<div class="sh-head"><span class="sh-ic"></span><span class="sh-t"></span><button class="x" title="Never mind">✕</button></div>' +
        '<div class="sh-body"></div><div class="sh-text"></div><div class="sh-btns"></div><div class="sh-bar" hidden><i></i></div>';
      card.querySelector('.x').addEventListener('click', e => { e.stopPropagation(); post('cancel'); });
      card.querySelector('.x').addEventListener('mousedown', e => e.stopPropagation());
      card.addEventListener('mouseenter', () => { if (card.querySelector('.sh-bar.run')) { card.querySelector('.sh-bar').classList.add('held'); post('hold'); } });
      card.querySelector('.sh-head').addEventListener('mousedown', () => { card.dataset.moved = '1'; });
      X.dragBy(card.querySelector('.sh-head'), card);
      X.cards.appendChild(card);
      fresh = true;
    }
    const c = card;
    c.classList.remove('sent', 'error', 'waiting', 'got', 'confirm', 'ready');
    c.classList.add(o.state || 'got');
    c.querySelector('.sh-ic').textContent = o.icon || '📱';
    const t = c.querySelector('.sh-t'); t.textContent = o.title || ''; t.dir = window.textDir ? window.textDir(o.title || '') : 'auto';
    c.dataset.label = o.title || '';
    const body = c.querySelector('.sh-body');
    body.innerHTML = '';
    body.classList.toggle('many', (o.thumbs || []).length > 1);
    if (o.state === 'waiting' || o.state === 'error') {
      body.innerHTML = '<div class="phone"></div>';
    } else if (o.state === 'sent') {
      body.innerHTML = '<div class="ok"></div>';
      body.querySelector('.ok').textContent = o.text || '✓';
    }
    const thumbs = o.state === 'sent' ? [] : (o.thumbs || []);
    thumbs.slice(0, thumbs.length > 4 ? 3 : 4).forEach(src => { const i = document.createElement('img'); i.src = src; body.appendChild(i); });
    if (thumbs.length > 4) { const m = document.createElement('span'); m.className = 'more'; m.textContent = '+' + (thumbs.length - 3); body.appendChild(m); }
    const text = c.querySelector('.sh-text');
    text.textContent = o.state === 'sent' ? '' : (o.text || '');
    text.dir = window.textDir ? window.textDir(o.text || '') : 'auto';
    const btns = c.querySelector('.sh-btns');
    btns.innerHTML = '';
    for (const b of o.buttons || []) {
      const e = document.createElement('button');
      e.textContent = b.label; if (b.primary) e.className = 'primary';
      e.dataset.id = b.id;
      e.addEventListener('mousedown', ev => ev.stopPropagation());
      e.addEventListener('click', ev => {
        ev.stopPropagation();
        const r = e.getBoundingClientRect();
        post(b.id, { x: Math.round(r.left + r.width / 2), y: Math.round(r.bottom) });
      });
      btns.appendChild(e);
    }
    btns.hidden = !(o.buttons || []).length;
    const bar = c.querySelector('.sh-bar');
    bar.classList.remove('run', 'held');
    bar.hidden = !(o.countdown > 0);
    if (o.countdown > 0) { bar.style.setProperty('--secs', o.countdown + 's'); void bar.offsetWidth; bar.classList.add('run'); }
    if (fresh) place(c);
    if (o.state === 'sent') {
      void c.offsetWidth;
      c.classList.add('sent');
      sentTimer = setTimeout(() => { if (card === c) { c.remove(); card = null; X.report(); } }, 1600);
    }
    X.report();
  };

  /** Tests: what the card shows. */
  SB.workPhotoState = () => card && card.isConnected ? {
    state: ['waiting', 'got', 'confirm', 'ready', 'error', 'sent'].find(s => card.classList.contains(s)) || '',
    title: card.querySelector('.sh-t').textContent, text: card.querySelector('.sh-text').textContent,
    thumbs: card.querySelectorAll('.sh-body img').length,
    buttons: [...card.querySelectorAll('.sh-btns button')].map(b => b.dataset.id),
    countdown: !card.querySelector('.sh-bar').hidden,
    box: (r => [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)])(card.getBoundingClientRect()),
  } : null;
  /** Tests: as if a button was clicked. */
  SB.workPhotoClick = id => { const b = card && card.querySelector(`.sh-btns button[data-id="${id}"]`); if (b) b.click(); return !!b; };

  // ---------- pictures dropped on the paper or a card ----------
  // The overlay takes the mouse only over its cards, so that's where a drop can land. Anything else dropped is
  // refused here (a file the page didn't take would replace the overlay with it).
  const isPicture = f => /^image\//.test(f.type) || f.type === 'application/pdf' || /\.(pdf|heic|heif|png|jpe?g|tiff?|webp)$/i.test(f.name || '');
  const hasFiles = e => [...(e.dataTransfer && e.dataTransfer.types || [])].includes('Files');
  let dragDepth = 0;
  addEventListener('dragenter', e => { if (!hasFiles(e)) return; e.preventDefault(); dragDepth++; document.body.classList.add('photo-drop'); });
  addEventListener('dragover', e => { e.preventDefault(); if (e.dataTransfer) e.dataTransfer.dropEffect = hasFiles(e) ? 'copy' : 'none'; });
  addEventListener('dragleave', () => { if (--dragDepth <= 0) { dragDepth = 0; document.body.classList.remove('photo-drop'); } });
  addEventListener('drop', e => {
    e.preventDefault();
    dragDepth = 0; document.body.classList.remove('photo-drop');
    const files = [...(e.dataTransfer && e.dataTransfer.files || [])].filter(isPicture).slice(0, 8);
    if (!files.length) return;
    Promise.all(files.map(f => new Promise(res => {
      const r = new FileReader();
      r.onload = () => res({ name: f.name || '', type: f.type || '', data: r.result });
      r.onerror = () => res(null);
      r.readAsDataURL(f);
    }))).then(list => { list = list.filter(Boolean); if (list.length) post('drop', { files: list }); });
  });
})();

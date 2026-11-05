/* Poinky 3D kit: a tiny layer over three.js so the artist model can build
   illustrated 3D models quickly: simple parts, callout tags, flowing arrows.
   Used inside a sandboxed iframe as:  Kit() → kit.box(...), kit.label(...), kit.start() */
(function () {
  const PALETTE = {
    blue: '#3b6ef6', green: '#2fa36b', red: '#e5484d', yellow: '#e0a800', purple: '#8e4ec6',
    orange: '#f76b15', teal: '#12a594', pink: '#d6409f', gray: '#9aa0aa', white: '#f4f5f7',
    dark: '#3a3f47', metal: '#b9bec7', light: '#d9dce1', black: '#25282d', gold: '#d4a017',
    pcb: '#2f8f5b', copper: '#c27a3a', glass: '#bcd7ff',
  };
  const TAG_BG = { blue: '#eef3ff', green: '#eafaf1', red: '#fdeeee', yellow: '#fff8dc', purple: '#f5edfc',
                   orange: '#fff1e6', teal: '#e6f7f5', pink: '#fcebf5', gray: '#f3f4f6' };
  const DEG = Math.PI / 180;

  // ---------- running the model's code statement by statement ----------
  // The code streams in while the model writes it. Each complete top-level statement runs as soon
  // as it has arrived, so the model builds up live. Returns the complete statements and the
  // unfinished rest. `final`: no more text is coming.
  const CONT_END = ',([{=+-*/&|?:.!<>%^~';
  function splitStatements(src, final) {
    const out = [];
    let depth = 0, q = null, esc = false, lineC = false, blockC = false, start = 0, last = '', lastIdx = -1, headerEnd = -1;
    const push = end => {
      const s = src.slice(start, end).trim().replace(/^```\w*\s*/, '').replace(/\s*```$/, '');
      if (s) out.push(s);
      start = end; last = ''; lastIdx = -1; headerEnd = -1;
    };
    for (let i = 0; i < src.length; i++) {
      const c = src[i], d = src[i + 1];
      if (q) { if (esc) esc = false; else if (c === '\\') esc = true; else if (c === q || (c === '\n' && q !== '`')) q = null; continue; }
      if (blockC) { if (c === '*' && d === '/') { blockC = false; i++; } continue; }
      if (lineC) { if (c !== '\n') continue; lineC = false; }
      else if (c === '`' && src.startsWith('```', i) && (i === 0 || src[i - 1] === '\n')) { lineC = true; continue; }   // a ``` fence line
      else if (c === '/' && d === '/') { lineC = true; i++; continue; }
      else if (c === '/' && d === '*') { blockC = true; i++; continue; }
      if (c === '"' || c === "'" || c === '`') { q = c; last = c; lastIdx = i; continue; }
      if (c === '(' || c === '[' || c === '{') { depth++; last = c; lastIdx = i; continue; }
      if (c === ')' || c === ']' || c === '}') {
        depth = Math.max(0, depth - 1); last = c; lastIdx = i;
        // "if (…)" / "for (…)" / "while (…)" with the body on the next line
        if (c === ')' && depth === 0 && headerEnd < 0 && /^(if|for|while)\s*\(/.test(src.slice(start, i).trim())) headerEnd = i;
        continue;
      }
      if (depth > 0) { if (!/\s/.test(c)) { last = c; lastIdx = i; } continue; }
      if (c === ';') { push(i + 1); continue; }
      if (c === '\n') {
        if (!last || CONT_END.includes(last) || lastIdx === headerEnd) continue;
        if (/\belse$/.test(src.slice(start, i).trim())) continue;
        let j = i + 1; while (j < src.length && /\s/.test(src[j])) j++;
        if (j >= src.length) break;                       // wait to see how the next line starts
        const next = src.slice(j, j + 9);
        // the next line might still turn out to be "else …" / "catch …"
        if (!final && next.length < 9 && /^[a-z]*$/.test(next) && ['else', 'catch', 'finally'].some(w => w.startsWith(next))) break;
        if (!/^\/[\/*]/.test(next) && (/^[.?:,)\]}+\-*\/&|=<>%^]/.test(next) || /^(else|catch|finally)\b/.test(next))) continue;
        push(i + 1);
        continue;
      }
      if (!/\s/.test(c)) { last = c; lastIdx = i; }
    }
    if (final) push(src.length);
    return { stmts: out, rest: final ? '' : src.slice(start) };
  }

  // Top-level declarations become shared variables, so later statements and later steps can use them
  // ("const fan = …" now, "kit.spin(fan)" two sentences later). Returns the rewritten statement and its names.
  const IDENT = /^[A-Za-z_$][\w$]*/;
  function hoist(stmt) {
    // Comments written above a statement arrive with it ("// City\nconst city = …").
    stmt = stmt.replace(/^(?:\s*(?:\/\/[^\n]*(?:\n|$)|\/\*[\s\S]*?\*\/))+\s*/, '');
    let m = /^(const|let|var)\s+/.exec(stmt);
    if (m) {
      const body = stmt.slice(m[0].length);
      if (body[0] === '{' || body[0] === '[') {   // destructuring: ({a, b} = …)
        const close = matchClose(body, 0);
        const names = (body.slice(0, close + 1).match(/[A-Za-z_$][\w$]*(?!\s*:)/g) || []);
        return { code: '(' + body.replace(/;\s*$/, '') + ');', names };
      }
      const names = [];
      let depth = 0, q = null, expectName = true;
      for (let i = 0; i < body.length; i++) {
        const c = body[i];
        if (q) { if (c === '\\') i++; else if (c === q) q = null; continue; }
        if (expectName && /\S/.test(c)) { const id = IDENT.exec(body.slice(i)); if (id) names.push(id[0]); expectName = false; }
        if (c === '"' || c === "'" || c === '`') q = c;
        else if ('([{'.includes(c)) depth++;
        else if (')]}'.includes(c)) depth--;
        else if (c === ',' && depth === 0) expectName = true;
      }
      return { code: body, names };
    }
    m = /^(function\s*\*?|class)\s+([A-Za-z_$][\w$]*)/.exec(stmt);
    if (m) return { code: m[2] + ' = ' + stmt, names: [m[2]] };
    return { code: stmt, names: [] };
  }
  function matchClose(s, i) {
    let depth = 0;
    for (; i < s.length; i++) { if ('([{'.includes(s[i])) depth++; else if (')]}'.includes(s[i]) && --depth === 0) return i; }
    return s.length - 1;
  }

  window.Kit = function (opts) {
    opts = opts || {};
    const T = THREE;
    const stage = document.getElementById('stage');
    const linesSvg = document.getElementById('lines');
    const tagsDiv = document.getElementById('tags');
    const W = () => stage.clientWidth || innerWidth, H = () => stage.clientHeight || innerHeight;

    const renderer = new T.WebGLRenderer({ antialias: true, alpha: true, stencil: true });
    renderer.localClippingEnabled = true;   // for kit.cut / kit.cutaway
    renderer.setPixelRatio(Math.min(devicePixelRatio || 1, 2));
    renderer.setSize(W(), H());
    renderer.setClearColor(0x000000, 0);
    renderer.outputColorSpace = T.SRGBColorSpace;
    renderer.toneMapping = T.ACESFilmicToneMapping;
    renderer.toneMappingExposure = 1.08;
    renderer.shadowMap.enabled = true;
    renderer.shadowMap.type = T.PCFSoftShadowMap;
    stage.appendChild(renderer.domElement);

    const scene = new T.Scene();
    const camera = new T.PerspectiveCamera(32, W() / H(), 0.01, 5000);
    scene.add(new T.HemisphereLight(0xffffff, 0x9aa0aa, 0.8));   // low: the studio map below lights things too
    const sun = new T.DirectionalLight(0xffffff, 2.4); sun.position.set(5, 9, 7); scene.add(sun); scene.add(sun.target);
    sun.castShadow = true;
    sun.shadow.mapSize.set(2048, 2048);
    sun.shadow.bias = -0.0004; sun.shadow.normalBias = 0.02; sun.shadow.radius = 4;
    const rim = new T.DirectionalLight(0xc8d8ff, 0.9); rim.position.set(-7, 3, -6); scene.add(rim);
    // Studio reflections: a few soft white boxes around a grey room, baked into an environment map
    // so metal, gold and glass have something to reflect (without it they read as flat grey).
    try {
      const room = new T.Scene();
      room.background = new T.Color('#8d939c');
      const softbox = (w, h, at, k) => {
        const m = new T.Mesh(new T.PlaneGeometry(w, h), new T.MeshBasicMaterial({ color: new T.Color(1, 1, 1).multiplyScalar(k), side: T.DoubleSide }));
        m.position.set(...at); m.lookAt(0, 0, 0); room.add(m);
      };
      softbox(8, 8, [0, 6, 1], 2.4);      // overhead
      softbox(2.5, 8, [6, 1.5, 3], 1.5);  // key strip, right
      softbox(2.5, 8, [-6, 1.5, 2], 0.9); // fill strip, left
      softbox(8, 2, [0, 0.5, -6], 0.6);   // low back light
      const pm = new T.PMREMGenerator(renderer);
      scene.environment = pm.fromScene(room, 0.04).texture;
      pm.dispose();
    } catch (e) {}
    const world = new T.Group(); scene.add(world);

    const anims = [], labels = [], timers = [];
    const capsGroup = new T.Group(); scene.add(capsGroup);   // filled faces of cut parts
    let t0 = performance.now(), last = t0;
    const cam = { az: 32 * DEG, el: 20 * DEG, dist: 10, target: new T.Vector3(), baseAz: 32 * DEG, sway: true, spin: 0 };
    let lastInteract = -1e9, camTween = null, focused = false, focusCount = 0;
    let building = false, viewChosen = false;   // building: the model's first code is still arriving
    let clock = 0;                       // seconds since start (for things added later)
    let fitted = false, shadow = null, floor = true;   // floor: the soft shadow under the model (off for things in space)
    cam.goalTarget = new T.Vector3(); cam.goalDist = 10;
    // Narrated steps that have a line in the notes beside the model: where the camera ended up for each one
    // and its notes-about-this-moment labels, so clicking a note shows that step again.
    let curNote = null, viewingNote = null;
    const noteViews = {}, noteTemps = {};

    // ---------- helpers ----------
    const color = c => new T.Color(PALETTE[c] || c || PALETTE.metal);
    function material(o) {
      const glass = o.glass || o.color === 'glass';
      return new T.MeshStandardMaterial({
        color: color(o.color),
        roughness: o.rough ?? (o.metal ? 0.35 : 0.6),
        metalness: o.metal ? 0.6 : 0.05,
        transparent: glass || (o.opacity ?? 1) < 1,
        opacity: glass ? 0.35 : (o.opacity ?? 1),
        emissive: o.glow ? color(o.glow === true ? o.color : o.glow) : new T.Color(0),
        emissiveIntensity: o.glow ? 0.6 : 0,
        side: T.DoubleSide,
        flatShading: !!o.flat,
      });
    }
    function orientGeo(geo, axis) { // geometries are built along Y; turn them to X or Z
      if (axis === 'x') geo.rotateZ(-Math.PI / 2);
      else if (axis === 'z') geo.rotateX(Math.PI / 2);
      return geo;
    }
    function place(obj, o) {
      const p = o.at || [0, 0, 0];
      obj.position.set(p[0] || 0, p[1] || 0, p[2] || 0);
      if (o.rot) obj.rotation.set((o.rot[0] || 0) * DEG, (o.rot[1] || 0) * DEG, (o.rot[2] || 0) * DEG);
      if (o.scale) Array.isArray(o.scale) ? obj.scale.set(...o.scale) : obj.scale.setScalar(o.scale);
      if (o.name) obj.name = o.name;
      if (obj.isMesh) { obj.castShadow = true; obj.receiveShadow = true; }
      if (obj.isMesh && o.edges !== false) {
        const e = new T.LineSegments(new T.EdgesGeometry(obj.geometry, o.edgeAngle || 28),
          new T.LineBasicMaterial({ color: 0x1b1e24, transparent: true, opacity: 0.2 }));
        obj.add(e);
      }
      (o.parent || world).add(obj);
      return obj;
    }
    const mesh = (geo, o) => place(new T.Mesh(geo, material(o)), o);
    function roundedBox(w, h, d, r) {
      const b = r * 0.7, x = w / 2 - b, y = h / 2 - b, cr = Math.max(0.0005, r - b);
      const sh = new T.Shape();
      sh.moveTo(-x + cr, -y); sh.lineTo(x - cr, -y); sh.quadraticCurveTo(x, -y, x, -y + cr);
      sh.lineTo(x, y - cr); sh.quadraticCurveTo(x, y, x - cr, y); sh.lineTo(-x + cr, y);
      sh.quadraticCurveTo(-x, y, -x, y - cr); sh.lineTo(-x, -y + cr); sh.quadraticCurveTo(-x, -y, -x + cr, -y);
      const depth = Math.max(0.0005, d - 2 * b);
      const geo = new T.ExtrudeGeometry(sh, { depth, bevelEnabled: true, bevelThickness: b, bevelSize: b, bevelSegments: 3, curveSegments: 5 });
      geo.translate(0, 0, -depth / 2);
      geo.computeVertexNormals();
      return geo;
    }
    // Parts drop in one after another (when the model appears, and when steps add parts).
    const intros = [];
    let introAt = -1;   // when the last drop-in starts: parts arriving in quick succession cascade
    function buildIn(objs, startDelay, gap = 0.07) {
      objs.forEach(o => {
        if (o.userData.introduced) return;
        o.userData.introduced = true;
        const b = new T.Box3().setFromObject(o), hgt = b.isEmpty() ? 1 : b.getSize(new T.Vector3()).y;
        const t0 = Math.max(clock + startDelay, introAt + gap); introAt = t0;
        intros.push({ o, s: o.scale.clone(), y: o.position.y, lift: Math.max(hgt, 0.3) * 1.2, t0, dur: 0.55 });
        o.scale.multiplyScalar(0.0001);
      });
    }
    const isInside = (o, anc) => { for (let p = o; p; p = p.parent) if (p === anc) return true; return false; };
    // Finish a part's drop-in right away (before moving, copying or cutting it).
    function settle(obj) {
      for (let i = intros.length - 1; i >= 0; i--) {
        const a = intros[i];
        if (isInside(obj, a.o) || isInside(a.o, obj)) { a.o.scale.copy(a.s); a.o.position.y = a.y; intros.splice(i, 1); }
      }
    }
    // Measure as if every part had finished dropping in (so framing doesn't jump while parts arrive).
    function measure(fn) {
      const saved = intros.map(a => [a.o, a.o.scale.clone(), a.o.position.y]);
      for (const a of intros) { a.o.scale.copy(a.s); a.o.position.y = a.y; }
      try { return fn(); } finally { for (const [o, sc, y] of saved) { o.scale.copy(sc); o.position.y = y; } }
    }
    const boxOf = obj => measure(() => new T.Box3().setFromObject(obj));
    // Timed animation: fn(eased 0→1, raw u) over dur seconds, after delay. loop: back and forth.
    const ease = u => u < 0.5 ? 4 * u * u * u : 1 - Math.pow(-2 * u + 2, 3) / 2;
    function tween(o, fn) { timers.push({ t0: clock + (o.delay ?? 0), dur: Math.max(0.001, o.dur ?? 1.2), loop: !!o.loop, fn }); }
    const AX = { x: new T.Vector3(1, 0, 0), y: new T.Vector3(0, 1, 0), z: new T.Vector3(0, 0, 1) };
    function matsOf(obj, withLines) {
      const out = new Set();
      obj.traverse(m => {
        if (m.userData.helper || !m.material || (m.isLineSegments && !withLines)) return;
        (Array.isArray(m.material) ? m.material : [m.material]).forEach(x => out.add(x));
      });
      return [...out];
    }
    let fadeSeq = 0;
    function fadeMats(mats, to, o, meshes) {
      mats.forEach(m => {
        if (m.userData.op0 === undefined) { m.userData.op0 = m.opacity; m.userData.tr0 = m.transparent; m.userData.dw0 = m.depthWrite; }
        if (!m.transparent) { m.transparent = true; m.needsUpdate = true; }
        if (to < 1) m.depthWrite = false;
      });
      (meshes || []).forEach(m => { if (m.userData.cs0 === undefined) m.userData.cs0 = m.castShadow; m.castShadow = to > 0.5 && m.userData.cs0; });
      // A newer fade of the same part takes over from an older one that's still running.
      const id = ++fadeSeq;
      mats.forEach(m => { m.userData.fadeId = id; });
      let from = null;
      tween({ dur: o.dur ?? 0.8, delay: o.delay ?? 0 }, (e, u) => {
        const mine = mats.filter(m => m.userData.fadeId === id);
        if (!from) from = new Map(mats.map(m => [m, m.opacity]));
        mine.forEach(m => { m.opacity = from.get(m) + (to * m.userData.op0 - from.get(m)) * e; });
        if (u >= 1 && to >= 1) mine.forEach(m => { m.transparent = m.userData.tr0; m.depthWrite = m.userData.dw0; m.needsUpdate = true; });
        if (u >= 1 && o.done && mine.length) o.done();
      });
    }
    const meshesOf = obj => { const out = []; obj.traverse(m => { if (m.isMesh && !m.userData.helper) out.push(m); }); return out; };
    function aimCamera(az, el, dur) {
      camTween = { az0: cam.baseAz, el0: cam.el, az1: az, el1: Math.max(-80 * DEG, Math.min(85 * DEG, el)), t0: clock, dur: Math.max(0.05, dur) };
      if (fitted && !focused) fit();   // a new angle can need a different distance
    }
    // A step's camera: where it was heading when the next step started (or when you looked back).
    function saveView(note) {
      if (note == null || noteViews[note]) return;
      noteViews[note] = { az: camTween ? camTween.az1 : cam.baseAz, el: camTween ? camTween.el1 : cam.el,
                          target: cam.goalTarget.clone(), dist: cam.goalDist, focused, spin: cam.spin };
    }
    function showView(v, dur) {
      let az = v.az;
      while (az - cam.baseAz > Math.PI) az -= 2 * Math.PI;
      while (az - cam.baseAz < -Math.PI) az += 2 * Math.PI;
      camTween = { az0: cam.baseAz, el0: cam.el, az1: az, el1: v.el, t0: clock, dur };
      cam.goalTarget.copy(v.target); cam.goalDist = v.dist; focused = v.focused; cam.spin = v.spin || 0;
    }
    const camDir = () => new T.Vector3(Math.cos(cam.el) * Math.sin(cam.baseAz), Math.sin(cam.el), Math.cos(cam.el) * Math.cos(cam.baseAz));
    function pivotOf(obj, p) {
      const key = String(p);
      if (obj.parent && obj.parent.userData.pivotKey === key) return obj.parent;
      const parent = obj.parent || world;
      parent.updateWorldMatrix(true, false);
      const lp = parent.worldToLocal(v3(p));
      const pv = new T.Group();
      pv.position.copy(lp); pv.userData = { noIntro: true, introduced: true, pivotKey: key };
      parent.add(pv); obj.position.sub(lp); pv.add(obj);
      return pv;
    }
    let hatch = null;
    function hatchTexture(repeat) {
      if (!hatch) {
        const cv = document.createElement('canvas'); cv.width = cv.height = 32;
        const g = cv.getContext('2d');
        g.fillStyle = '#fff'; g.fillRect(0, 0, 32, 32);
        g.strokeStyle = 'rgba(0,0,0,0.16)'; g.lineWidth = 2.5;
        for (const k of [-32, 0, 32]) { g.beginPath(); g.moveTo(k, 32); g.lineTo(k + 32, 0); g.stroke(); }
        hatch = new T.CanvasTexture(cv); hatch.colorSpace = T.SRGBColorSpace;
        hatch.wrapS = hatch.wrapT = T.RepeatWrapping;
      }
      const t = hatch.clone(); t.repeat.set(repeat, repeat); t.needsUpdate = true;
      return t;
    }
    // Cut a part with a plane that sweeps in from the camera's side. fill: cover the cut faces
    // (solid things: fruit, Earth, a cable); without fill you look into hollow shells (a fuselage, a house).
    let capSeq = 0;
    const capList = [];
    function cutPart(obj, o, fill) {
      if (!obj) return null;
      if (obj.userData.cut) kit.uncut(obj, { dur: 0 });
      settle(obj);
      const box = boxOf(obj); if (box.isEmpty()) return null;
      const size = box.getSize(new T.Vector3()), c = box.getCenter(new T.Vector3()), view = camDir();
      const name = AX[o.axis] ? o.axis : (Math.abs(view.x) > Math.abs(view.z) ? 'x' : 'z');
      const a = AX[name], sgn = Math.sign(view.dot(a)) || 1;   // the half facing the camera goes
      const n = a.clone().multiplyScalar(-sgn);
      const at = o.at ?? c[name];
      const edge = (sgn > 0 ? box.max : box.min)[name] + sgn * 0.02 * size.length();
      const plane = new T.Plane(n, 0);
      const setAt = x => { plane.constant = sgn * x; };
      setAt(edge);
      tween({ dur: o.dur ?? 1.4, delay: o.delay ?? 0 }, e => setAt(edge + (at - edge) * e));
      matsOf(obj, true).forEach(m => { m.clippingPlanes = [...(m.clippingPlanes || []), plane]; m.clipShadows = true; m.needsUpdate = true; });
      const caps = [];
      if (fill) {
        const spacing = Math.max(contentBox().getSize(new T.Vector3()).length() / 70, 0.005);
        meshesOf(obj).filter(m => m.material && !m.material.transparent)
          .map(m => [m, boxOf(m)]).sort((p, q) => q[1].getSize(new T.Vector3()).length() - p[1].getSize(new T.Vector3()).length())
          .forEach(([m, b]) => {
            const order = 1000 + (capSeq++) * 2;
            for (const [side, op] of [[T.BackSide, T.IncrementWrapStencilOp], [T.FrontSide, T.DecrementWrapStencilOp]]) {
              const sm = new T.Mesh(m.geometry, new T.MeshBasicMaterial({ side, colorWrite: false, depthWrite: false, depthTest: false,
                stencilWrite: true, stencilFunc: T.AlwaysStencilFunc, stencilFail: op, stencilZFail: op, stencilZPass: op, clippingPlanes: [plane] }));
              sm.renderOrder = order; sm.userData.helper = true; sm.userData.plane = plane; sm.raycast = () => {};
              m.add(sm);
            }
            const r = b.getSize(new T.Vector3()).length() * 0.6 + 0.01;
            const cap = new T.Mesh(new T.PlaneGeometry(2 * r, 2 * r), new T.MeshStandardMaterial({
              color: m.userData.capColor ? m.userData.capColor.clone() : m.material.color ? m.material.color.clone() : color('light'), map: hatchTexture(2 * r / spacing / 4), roughness: 0.85,
              side: T.DoubleSide, polygonOffset: true, polygonOffsetFactor: -1, polygonOffsetUnits: -2 * (capSeq % 40),   // inner layers' faces win
              stencilWrite: true, stencilRef: 0, stencilFunc: T.NotEqualStencilFunc,
              stencilFail: T.ReplaceStencilOp, stencilZFail: T.ReplaceStencilOp, stencilZPass: T.ReplaceStencilOp }));
            cap.renderOrder = order + 1; cap.userData.helper = true;
            capsGroup.add(cap);
            const entry = { cap, mid: b.getCenter(new T.Vector3()), plane };
            caps.push(entry); capList.push(entry);
          });
      }
      obj.userData.cut = { plane, caps, edge, at, setAt, axis: name, sgn };
      return obj;
    }
    const easeBack = u => { const c1 = 1.4, c3 = c1 + 1; return 1 + c3 * Math.pow(u - 1, 3) + c1 * Math.pow(u - 1, 2); };
    const v3 = a => (a && a.isVector3) ? a.clone() : new T.Vector3(a[0] || 0, a[1] || 0, a[2] || 0);
    function worldPoint(target) {
      if (Array.isArray(target) || (target && target.isVector3)) return v3(target);
      if (target && target.isObject3D) { const b = new T.Box3().setFromObject(target); return b.getCenter(new T.Vector3()); }
      return new T.Vector3();
    }

    const kit = {
      THREE: T, scene, camera, world, renderer, _scene: world,

      group(o = {}) { return place(new T.Group(), { ...o, edges: false }); },
      /** A box with softly rounded edges (round: 0 for sharp). */
      box(o = {}) {
        const s = o.size || [1, 1, 1];
        const r = Math.min(o.round ?? Math.min(s[0], s[1], s[2]) * 0.08, 0.3, Math.min(s[0], s[1], s[2]) / 2 - 0.001);
        if (!(r > 0.004)) return mesh(new T.BoxGeometry(s[0], s[1], s[2]), o);
        return mesh(roundedBox(s[0], s[1], s[2], r), { ...o, edgeAngle: 45 });
      },
      /** A soft floor that only shows shadows (use it instead of a big dark slab). */
      ground(o = {}) {
        const size = o.size || [20, 20];
        const g = new T.Mesh(new T.PlaneGeometry(size[0], size[1]),
          o.color ? material({ color: o.color, opacity: o.opacity ?? 0.35 }) : new T.ShadowMaterial({ opacity: 0.25 }));
        g.rotation.x = -Math.PI / 2; g.receiveShadow = true;
        const p = o.at || [0, 0, 0]; g.position.set(p[0], p[1], p[2]);
        g.userData.isGround = true;
        world.add(g);
        return g;
      },
      /** A simple person for scale (height in your scene units, default 1.75). */
      person(o = {}) {
        const h = o.height ?? 1.75, g = new T.Group();
        const m = material({ color: o.color || 'gray' });
        const body = new T.Mesh(new T.CylinderGeometry(h * 0.11, h * 0.13, h * 0.55, 16), m); body.position.y = h * 0.5;
        const legs = new T.Mesh(new T.CylinderGeometry(h * 0.1, h * 0.09, h * 0.42, 16), m); legs.position.y = h * 0.2;
        const head = new T.Mesh(new T.SphereGeometry(h * 0.1, 20, 14), m); head.position.y = h * 0.88;
        [body, legs, head].forEach(x => { x.castShadow = true; g.add(x); });
        return place(g, { ...o, edges: false });
      },
      /** A dimension line between two points with its measurement as a tag ("120 m"). */
      measure(o = {}) {
        const a = v3(o.from || [0, 0, 0]), b = v3(o.to || [1, 0, 0]);
        const col = o.color || 'dark', g = new T.Group();
        const len = a.distanceTo(b), r = Math.max(len * 0.006, 0.01);
        const mat = material({ color: col });
        const bar = new T.Mesh(new T.CylinderGeometry(r, r, len, 8), mat);
        bar.position.copy(a).add(b).multiplyScalar(0.5);
        bar.quaternion.setFromUnitVectors(new T.Vector3(0, 1, 0), b.clone().sub(a).normalize());
        g.add(bar);
        for (const end of [a, b]) {
          const tick = new T.Mesh(new T.SphereGeometry(r * 2.4, 10, 8), mat); tick.position.copy(end); g.add(tick);
        }
        world.add(g);
        if (o.label) kit.label(o.label, { at: a.clone().add(b).multiplyScalar(0.5).toArray(), color: o.labelColor || 'gray' });
        return g;
      },
      cylinder(o = {}) {
        const r = o.r ?? 0.5;
        const geo = new T.CylinderGeometry(o.rTop ?? r, o.rBottom ?? r, o.h ?? 1, o.segments || 40, 1, !!o.open);
        return mesh(orientGeo(geo, o.axis), o);
      },
      cone(o = {}) { return kit.cylinder({ ...o, rTop: 0, rBottom: o.r ?? 0.5 }); },
      sphere(o = {}) {
        const m = mesh(new T.SphereGeometry(o.r ?? 0.5, 40, 24), { ...o, edges: false });
        if (o.stretch) m.scale.set(...o.stretch);
        return m;
      },
      torus(o = {}) { return mesh(orientGeo(new T.TorusGeometry(o.r ?? 0.5, o.tube ?? 0.12, 16, 48).rotateX(Math.PI / 2), o.axis), o); },
      /** Flat shape from 2D points, given thickness. plane: 'xy' (default), 'xz' (lying flat), 'yz'. */
      extrude(o = {}) {
        const pts = (o.points || [[0, 0], [1, 0], [0, 1]]).map(p => new T.Vector2(p[0], p[1]));
        const depth = o.depth ?? 0.1;
        const geo = new T.ExtrudeGeometry(new T.Shape(pts), { depth, bevelEnabled: !!o.bevel, bevelSize: 0.02, bevelThickness: 0.02, bevelSegments: 2 });
        geo.translate(0, 0, -depth / 2);
        if (o.plane === 'xz') geo.rotateX(-Math.PI / 2);
        else if (o.plane === 'yz') geo.rotateY(Math.PI / 2);
        return mesh(geo, o);
      },
      /** Round body from a side profile [[radius, position], ...] (fuselages, bottles, nose cones). */
      lathe(o = {}) {
        const pts = (o.points || [[0, 0], [0.5, 0.5], [0, 1]]).map(p => new T.Vector2(Math.max(0, p[0]), p[1]));
        return mesh(orientGeo(new T.LatheGeometry(pts, o.segments || 48), o.axis), { ...o, edges: o.edges ?? false });
      },
      /** Flat horizontal part (wings, boards, plates). points are [x, z] in world units; sits at height y. */
      plate(o = {}) {
        const pts = (o.points || [[0, 0], [1, 0], [0, 1]]).map(p => new T.Vector2(p[0], -p[1]));
        const th = o.thickness ?? 0.08;
        const geo = new T.ExtrudeGeometry(new T.Shape(pts), { depth: th, bevelEnabled: false });
        geo.translate(0, 0, -th / 2); geo.rotateX(-Math.PI / 2);
        const at = o.at || [0, o.y ?? 0, 0];
        return mesh(geo, { ...o, at });
      },
      /** Flat upright part (tail fins, walls, brackets). points are [x, y] in world units; sits at depth z. */
      fin(o = {}) {
        const pts = (o.points || [[0, 0], [1, 0], [0, 1]]).map(p => new T.Vector2(p[0], p[1]));
        const th = o.thickness ?? 0.06;
        const geo = new T.ExtrudeGeometry(new T.Shape(pts), { depth: th, bevelEnabled: false });
        geo.translate(0, 0, -th / 2);
        const at = o.at || [0, 0, o.z ?? 0];
        return mesh(geo, { ...o, at });
      },
      /** Long rounded body (fuselage, bottle, pen, rocket) along an axis from → to.
          radii: widths along the way (first = start, last = end). squash: [height, depth] factors to flatten it. */
      body(o = {}) {
        const from = o.from ?? -2, to = o.to ?? 2, radii = o.radii || [0, 0.5, 0.5, 0];
        const pts = radii.map((r, i) => new T.Vector2(Math.max(0.0001, r), from + (to - from) * i / (radii.length - 1)));
        const geo = new T.LatheGeometry(pts, 48);
        orientGeo(geo, o.axis || 'x');
        if (o.squash) {
          const [a, b] = o.squash, ax = o.axis || 'x';
          if (ax === 'x') geo.scale(1, a, b); else if (ax === 'y') geo.scale(a, 1, b); else geo.scale(a, b, 1);
        }
        return mesh(geo, { ...o, edges: false });
      },
      /** A pipe/cable through 3D points. */
      tube(o = {}) {
        const curve = new T.CatmullRomCurve3((o.points || [[0, 0, 0], [1, 0, 0]]).map(v3), !!o.closed);
        return mesh(new T.TubeGeometry(curve, o.segments || 64, o.r ?? 0.05, 12, !!o.closed), { ...o, edges: false });
      },
      /** Add any three.js object you built yourself (a custom geometry, a THREE.Points cloud…) to the model. */
      add(obj, o = {}) {
        if (!obj || !obj.isObject3D) return obj;
        return place(obj, { ...o, edges: o.edges ?? false });
      },
      /** A flat ribbon cable / strap / belt / road along points (width × thickness cross-section). */
      ribbon(o = {}) {
        // Built by hand (not ExtrudeGeometry) so the flat side keeps facing up instead of twisting along the path.
        const curve = new T.CatmullRomCurve3((o.points || [[0, 0, 0], [1, 0, 0]]).map(v3));
        const w = o.width ?? 0.3, th = o.thickness ?? 0.03, n = o.segments || 64, up = v3(o.up || [0, 1, 0]).normalize();
        const corners = [[-1, -1], [1, -1], [1, 1], [-1, 1]], pos = [], idx = [];
        let side = null;
        for (let i = 0; i <= n; i++) {
          const p = curve.getPointAt(i / n), t = curve.getTangentAt(i / n);
          let s = new T.Vector3().crossVectors(t, up);
          if (s.lengthSq() < 1e-4) s = side ? side.clone() : new T.Vector3().crossVectors(t, AX.x);
          s.normalize();
          if (side && s.dot(side) < 0) s.negate();
          side = s;
          const nrm = new T.Vector3().crossVectors(s, t).normalize();
          for (const [a, b] of corners) pos.push(...p.clone().addScaledVector(s, a * w / 2).addScaledVector(nrm, b * th / 2).toArray());
        }
        for (let i = 0; i < n; i++) for (let c = 0; c < 4; c++) {
          const a = i * 4 + c, b = i * 4 + (c + 1) % 4, a2 = a + 4, b2 = b + 4;
          idx.push(a, a2, b, b, a2, b2);
        }
        idx.push(0, 1, 2, 0, 2, 3); const e = n * 4; idx.push(e, e + 2, e + 1, e, e + 3, e + 2);
        const geo = new T.BufferGeometry();
        geo.setAttribute('position', new T.Float32BufferAttribute(pos, 3)); geo.setIndex(idx);
        const flat = geo.toNonIndexed(); flat.computeVertexNormals();
        return mesh(flat, { ...o, edges: false });
      },
      /** A math surface: height = fn(x, y) over x:[a,b], y:[a,b] (math axes: x right, y back, height up).
          Colored by height unless you give a color. */
      surface(fn, o = {}) {
        if (typeof fn !== 'function') { o = fn || {}; fn = o.fn || (() => 0); }
        const [x0, x1] = o.x || [-2, 2], [y0, y1] = o.y || [-2, 2], n = o.res || 60, k = o.scale ?? 1;
        const geo = new T.PlaneGeometry(x1 - x0, y1 - y0, n, n);
        const pos = geo.attributes.position, cols = [], hs = [];
        for (let i = 0; i < pos.count; i++) {
          const x = pos.getX(i) + (x0 + x1) / 2, y = pos.getY(i) + (y0 + y1) / 2;
          let h = Number(fn(x, y)); if (!isFinite(h)) h = 0;
          hs.push(h); pos.setXYZ(i, x, h * k, -y);
        }
        const lo = Math.min(...hs), hi = Math.max(...hs);
        const c0 = new T.Color(PALETTE.blue), c1 = new T.Color(PALETTE.orange), c = new T.Color();
        hs.forEach(h => { c.copy(c0).lerp(c1, hi > lo ? (h - lo) / (hi - lo) : 0.5); cols.push(c.r, c.g, c.b); });
        if (!o.color) geo.setAttribute('color', new T.Float32BufferAttribute(cols, 3));
        geo.computeVertexNormals();
        const m = mesh(geo, { ...o, edges: false });
        if (!o.color) { m.material.vertexColors = true; m.material.color.set('#ffffff'); }
        if (o.grid !== false) {
          const wire = new T.LineSegments(new T.WireframeGeometry(geo), new T.LineBasicMaterial({ color: 0x1b1e24, transparent: true, opacity: 0.12 }));
          m.add(wire);
        }
        return m;
      },
      /** Math axes with arrowheads and x / y / z tags (math convention: z up). */
      axes(o = {}) {
        const L = o.size ?? 3, g = kit.group({ at: o.at, name: o.name || 'axes' });
        const dirs = [['x', [1, 0, 0]], ['y', [0, 0, -1]], ['z', [0, 1, 0]]];
        for (const [n, d] of dirs) {
          const from = d.map(v => -v * (o.negative === false ? 0 : L)), to = d.map(v => v * L);
          kit.arrow({ from, to, color: o.color || 'gray', flow: false, glow: false, r: L * 0.012, parent: g });
          if (o.labels !== false) kit.label((o.names && o.names[n]) || n, { at: d.map(v => v * L * 1.08), color: o.color || 'gray' });
        }
        return g;
      },
      /** Rolling ground with hills (a landscape for scenes: battlefields, valleys, maps). flat: radius of a flat middle. */
      terrain(o = {}) {
        const [w, d] = o.size || [40, 30], n = o.res || 90, hgt = o.height ?? Math.min(w, d) * 0.06;
        const geo = new T.PlaneGeometry(w, d, n, n); geo.rotateX(-Math.PI / 2);
        const pos = geo.attributes.position, seed = o.seed ?? 3, cols = [], c = new T.Color();
        const low = new T.Color(o.color ? PALETTE[o.color] || o.color : '#8fb36b'), high = new T.Color(o.high || '#c8b48a');
        for (let i = 0; i < pos.count; i++) {
          const x = pos.getX(i), z = pos.getZ(i);
          let h = 0, f = 1.6 / Math.min(w, d), a = 1;
          for (let k = 0; k < 4; k++) { h += a * Math.sin(x * f * 6.3 + seed * 1.7 + k) * Math.cos(z * f * 5.1 - seed + k * 2.1); f *= 2.1; a *= 0.45; }
          const r = Math.hypot(x, z), flat = o.flat ?? 0;
          h = hgt * (0.5 + 0.5 * h) * (flat ? Math.min(1, Math.max(0, (r - flat) / (flat + 1e-6))) : 1);
          pos.setY(i, h);
          c.copy(low).lerp(high, Math.min(1, h / (hgt || 1))); cols.push(c.r, c.g, c.b);
        }
        geo.setAttribute('color', new T.Float32BufferAttribute(cols, 3));
        geo.computeVertexNormals();
        const m = mesh(geo, { ...o, color: '#ffffff', edges: false, rough: 0.95 });
        m.material.vertexColors = true; m.castShadow = false;
        return m;
      },
      /** Send a part along a path (a rocket's flight, a planet's orbit, a blood cell…). It turns to face
          where it's going (face: which of its own axes points forward, default 'x'). trail: draw the path behind it. */
      travel(obj, o = {}) {
        if (!obj) return;
        settle(obj);
        const pts = (o.path || o.points || [[0, 0, 0], [1, 0, 0]]).map(v3);
        const curve = new T.CatmullRomCurve3(pts, !!o.closed);
        const fwd = AX[o.face || 'x'] || AX.x, q = new T.Quaternion(), base = obj.quaternion.clone();
        // Actors in a scene are drawn bigger than life so you can see them: at least ~1/14 of their path.
        if (!o.keepSize) {
          const d = boxOf(obj).getSize(new T.Vector3()).length(), want = Math.max(curve.getLength() / 14, contentBox().getSize(new T.Vector3()).length() / 18);
          if (d > 0 && d < want) {
            const s0 = obj.scale.clone(), k = Math.min(4, want / d);
            tween({ dur: 0.5, delay: Math.max(0, (o.delay ?? 0.2) - 0.3) }, e => obj.scale.copy(s0).multiplyScalar(1 + (k - 1) * e));
          }
        }
        let trail = null;
        if (o.trail !== false) {
          const tp = curve.getSpacedPoints(160);
          const geo = new T.BufferGeometry().setFromPoints(tp);
          trail = new T.Line(geo, new T.LineDashedMaterial({ color: color(o.trailColor || o.color || 'gray'), dashSize: 0.3, gapSize: 0.18, transparent: true, opacity: 0.8 }));
          trail.computeLineDistances(); geo.setDrawRange(0, 0); trail.userData.noIntro = true;
          (obj.parent || world).add(trail);
        }
        const go = (e) => {
          const p = curve.getPointAt(e), tan = curve.getTangentAt(Math.min(0.999, Math.max(0.001, e)));
          obj.position.copy(p);
          if (o.follow) { obj.updateWorldMatrix(true, false); cam.goalTarget.lerp(obj.getWorldPosition(new T.Vector3()), 0.12); focused = true; }
          if (o.turn !== false) obj.quaternion.copy(q.setFromUnitVectors(fwd, tan.normalize())).multiply(base);
          if (trail) trail.geometry.setDrawRange(0, Math.round(e * 160) + 1);
        };
        go(0);
        tween({ dur: o.dur ?? 3, delay: o.delay ?? 0.2, loop: o.loop }, go);
        return trail;
      },
      /** A blast: a bright flash that swells and fades, with sparks flying out (an explosion, an impact, a spark). */
      burst(o = {}) {
        const at = v3(o.at || [0, 0, 0]), r = o.size ?? 1, col = o.color || 'orange', g = new T.Group();
        g.position.copy(at); g.userData.noIntro = true; world.add(g);
        const ball = new T.Mesh(new T.SphereGeometry(r, 24, 16), new T.MeshBasicMaterial({ color: color(col), transparent: true, opacity: 0.9 }));
        g.add(ball);
        const sparks = [];
        for (let i = 0; i < 18; i++) {
          const s = new T.Mesh(new T.SphereGeometry(r * 0.08, 8, 6), new T.MeshBasicMaterial({ color: color(o.spark || 'yellow'), transparent: true }));
          const d = new T.Vector3(Math.random() - 0.5, Math.random() - 0.5, Math.random() - 0.5).normalize();
          g.add(s); sparks.push([s, d]);
        }
        tween({ dur: o.dur ?? 1.4, delay: o.delay ?? 0 }, (e, u) => {
          ball.scale.setScalar(0.2 + u * 1.3); ball.material.opacity = 0.9 * (1 - u);
          for (const [s, d] of sparks) { s.position.copy(d).multiplyScalar(r * 2.6 * Math.sqrt(u)); s.material.opacity = 1 - u; }
          if (u >= 1 && !o.keep) world.remove(g);
        });
        return g;
      },
      /** Rings that ripple out from a point (a radar ping, sound, a signal, a shock wave). */
      wave(o = {}) {
        const at = v3(o.at || [0, 0, 0]), R = o.r ?? 3, g = new T.Group(), n = o.count ?? 3;
        g.position.copy(at); g.userData.noIntro = true;
        if (o.axis === 'x') g.rotation.z = Math.PI / 2; else if (o.axis === 'z') g.rotation.x = Math.PI / 2;
        world.add(g);
        for (let i = 0; i < n; i++) {
          const ring = new T.Mesh(new T.TorusGeometry(1, 0.03, 8, 64).rotateX(Math.PI / 2), new T.MeshBasicMaterial({ color: color(o.color || 'teal'), transparent: true }));
          g.add(ring);
          anims.push(t => { const u = ((t * (o.speed ?? 0.5)) + i / n) % 1; ring.scale.setScalar(0.05 + u * R); ring.material.opacity = (1 - u) * 0.9; });
        }
        return g;
      },
      /** A cable between two parts (or points): the kit finds where they face each other. type: 'cable' or 'ribbon'.
          grow: true draws it from a to b over dur seconds ("plug it in"). sag > 0 droops, < 0 arcs up. */
      connect(a, b, o = {}) {
        if (!a || !b) return null;
        const pa = a.isObject3D ? boxOf(a) : null, pb = b.isObject3D ? boxOf(b) : null;
        const ca = pa ? pa.getCenter(new T.Vector3()) : v3(a), cb = pb ? pb.getCenter(new T.Vector3()) : v3(b);
        // Each end sits on its part's box, on the side facing the other part.
        const ea = o.fromAt ? v3(o.fromAt) : pa ? pa.clampPoint(cb, new T.Vector3()) : ca;
        const eb = o.toAt ? v3(o.toAt) : pb ? pb.clampPoint(ca, new T.Vector3()) : cb;
        const len = ea.distanceTo(eb), sag = (o.sag ?? -0.25) * len;
        const mid = ea.clone().lerp(eb, 0.5); mid.y -= sag;
        const pts = [ea, ea.clone().lerp(mid, 0.5).setY(ea.y - sag * 0.7), mid, mid.clone().lerp(eb, 0.5).setY(eb.y - sag * 0.7), eb].map(p => p.toArray());
        const thick = o.r ?? Math.max(0.02, len * 0.025);
        const m = o.type === 'ribbon' ? kit.ribbon({ points: pts, width: o.width ?? thick * 6, thickness: thick * 0.5, color: o.color || 'light', name: o.name })
                                      : kit.tube({ points: pts, r: thick, color: o.color || 'dark', name: o.name });
        if (o.grow) {
          m.userData.noIntro = true;
          const idx = m.geometry.index, total = idx ? idx.count : m.geometry.attributes.position.count;
          m.geometry.setDrawRange(0, 0);
          tween({ dur: o.dur ?? 1.6, delay: o.delay ?? 0.2 }, e => m.geometry.setDrawRange(0, Math.floor(total * e / 3) * 3));
        }
        return m;
      },
      /** A solid arrow from → to. flow: true adds little chevrons travelling along it. */
      arrow(o = {}) {
        const a = v3(o.from || [0, 0, 0]), b = v3(o.to || [0, -1, 0]);
        // Thickness follows the arrow's length, but long arrows (a flight path) don't turn into pipes.
        const dir = b.clone().sub(a), len = dir.length();
        const scene = contentBox(), diag = scene.isEmpty() ? len : scene.getSize(new T.Vector3()).length();
        const r = o.r ?? Math.max(0.02, Math.min(len * 0.035, Math.max(0.05, diag * 0.009)));
        const g = new T.Group(); g.position.copy(a);
        g.quaternion.setFromUnitVectors(new T.Vector3(0, 1, 0), dir.clone().normalize());
        const mat = material({ color: o.color || 'blue', glow: o.glow ?? true });
        const headLen = Math.min(len * 0.3, r * 6);
        const shaft = new T.Mesh(new T.CylinderGeometry(r, r, len - headLen, 16), mat); shaft.position.y = (len - headLen) / 2; g.add(shaft);
        const head = new T.Mesh(new T.ConeGeometry(r * 2.6, headLen, 20), mat); head.position.y = len - headLen / 2; g.add(head);
        if (o.flow !== false) {
          for (let i = 0; i < 3; i++) {
            const c = new T.Mesh(new T.ConeGeometry(r * 1.9, r * 3.2, 16), material({ color: 'white', glow: 'white', opacity: 0.9 }));
            g.add(c);
            anims.push(t => { const u = ((t * (o.speed ?? 0.6)) + i / 3) % 1; c.position.y = u * (len - headLen); c.material.opacity = Math.sin(u * Math.PI) * 0.9; });
          }
        }
        (o.parent || world).add(g);
        return g;
      },
      /** Particles streaming along a path, e.g. air or water flow. */
      flow(o = {}) {
        const curve = new T.CatmullRomCurve3((o.path || [[0, 0, 0], [0, -1, 0]]).map(v3));
        const n = o.count ?? 14, g = new T.Group();
        const mat = material({ color: o.color || 'blue', glow: true, opacity: 0.85 });
        for (let i = 0; i < n; i++) {
          const p = new T.Mesh(new T.SphereGeometry(o.size ?? 0.05, 10, 8), mat.clone()); g.add(p);
          anims.push(t => { const u = ((t * (o.speed ?? 0.4)) + i / n) % 1; p.position.copy(curve.getPointAt(u)); p.material.opacity = Math.sin(u * Math.PI); });
        }
        (o.parent || world).add(g);
        return g;
      },
      /** A callout tag with a leader line pointing at a spot or a part. It stays (part names build up a map
          of the model); temp: true makes a note about this moment that fades when the next step starts. */
      label(text, o = {}) {
        if (o && o.isObject3D) o = { to: o };                       // label('Fan', fan)
        if (text && text.isObject3D) [text, o] = [String(o && o.text || o || ''), { to: text }];
        if (Array.isArray(o)) o = { at: o };
        o = o || {};
        const c = o.color || 'blue', ink = PALETTE[c] || c;
        const tag = document.createElement('div');
        tag.className = o.temp ? 'tag temp' : 'tag';
        tag.textContent = String(text ?? '');
        tag.style.setProperty('--c', ink);
        tagsDiv.appendChild(tag);
        const line = document.createElementNS('http://www.w3.org/2000/svg', 'line');
        const dot = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
        line.setAttribute('stroke', ink); line.setAttribute('stroke-width', '2');
        if (o.temp) { tag.style.setProperty('--bg', TAG_BG[c] || '#fffdf8'); line.setAttribute('stroke-dasharray', '5 4'); }
        dot.setAttribute('r', '4'); dot.setAttribute('fill', '#fff'); dot.setAttribute('stroke', ink); dot.setAttribute('stroke-width', '2.5');
        linesSvg.appendChild(line); linesSvg.appendChild(dot);
        const target = o.at || o.to || o.target || [0, 0, 0];
        const L = { text, tag, line, dot, target, temp: !!o.temp, note: o._note ?? curNote,
                    side: o.side, anchor: null, x: null, y: null,
                    delay: clock + (fitted ? 0.5 : 0.9 + labels.length * 0.15) };
        labels.push(L);
        if (o.temp && curNote != null && o._note == null) (noteTemps[curNote] = noteTemps[curNote] || []).push([String(text ?? ''), { ...o }]);
        return L;
      },
      /** Run fn(t, dt) every frame. t is seconds since start. */
      animate(fn) { anims.push(fn); },
      spin(obj, axis = 'y', speed = 1) { anims.push((t, dt) => { obj.rotation[axis] += dt * speed; }); },
      /** Move an object to a position (or by an offset) over time. loop: true goes back and forth. */
      move(obj, o = {}) {
        if (!obj) return;
        settle(obj);
        const from = obj.position.clone(), to = o.by ? from.clone().add(v3(o.by)) : v3(o.to || [0, 0, 0]);
        tween({ dur: o.dur ?? 1.5, delay: o.delay ?? 0.5, loop: o.loop }, e => obj.position.lerpVectors(from, to, e));
      },
      /** Turn a part by degrees [x,y,z] (or to an absolute rotation), optionally around a pivot point (a hinge). */
      rotate(obj, o = {}) {
        if (!obj) return;
        settle(obj);
        const t = o.pivot ? pivotOf(obj, o.pivot) : obj;
        const from = t.rotation.clone(), d = (o.by || o.to || [0, 0, 0]).map(x => (x || 0) * DEG);
        const to = o.by ? [from.x + d[0], from.y + d[1], from.z + d[2]] : d;
        tween({ dur: o.dur ?? 1.2, delay: o.delay ?? 0.3, loop: o.loop },
          e => t.rotation.set(from.x + (to[0] - from.x) * e, from.y + (to[1] - from.y) * e, from.z + (to[2] - from.z) * e));
        return t;
      },
      /** Grow (or shrink) a part over time: from/to are size factors. axis: 'y' grows upward from its base. */
      grow(obj, o = {}) {
        if (!obj) return;
        settle(obj);
        const base = obj.userData.baseScale || (obj.userData.baseScale = obj.scale.clone());
        const y0 = obj.userData.baseY ?? (obj.userData.baseY = obj.position.y);
        const below = y0 - boxOf(obj).min.y;   // origin to bottom, at full size
        const f = o.from ?? 0, to = o.to ?? 1, ax = o.axis;
        const set = k => {
          const q = Math.max(k, 0.0001);
          obj.scale.set(!ax || ax === 'x' ? base.x * q : base.x, !ax || ax === 'y' ? base.y * q : base.y, !ax || ax === 'z' ? base.z * q : base.z);
          if (ax === 'y' && obj.parent === world) obj.position.y = y0 - below * (1 - q);   // keep its base on the ground
        };
        set(f);
        tween({ dur: o.dur ?? 1.5, delay: o.delay ?? 0, loop: o.loop }, e => set(f + (to - f) * e));
      },
      /** Change a part's color over time (heating up, a signal arriving, a state change). */
      tint(obj, o = {}) {
        if (!obj) return;
        const mats = matsOf(obj).filter(m => m.color), target = color(o.color || 'red'), from = mats.map(m => m.color.clone());
        tween({ dur: o.dur ?? 1, delay: o.delay ?? 0, loop: o.loop }, e => mats.forEach((m, i) => m.color.copy(from[i]).lerp(target, e)));
      },
      /** Copies of a part: around an axis (blades, teeth, petals, seats), in a row/grid (step), or along a path.
          part can be a function (i, n) => part to vary each copy. Returns a group of all copies. */
      repeat(part, o = {}) {
        const grid = o.grid, n = grid ? grid[0] * (grid[1] || 1) * (grid[2] || 1) : Math.max(1, Math.round(o.count ?? 6));
        const make = typeof part === 'function' ? i => part(i, n) : null;
        const first = make ? make(0) : part;
        if (!first || !first.isObject3D) return null;
        settle(first);
        const copies = [first];
        for (let i = 1; i < n; i++) {
          const c = make ? make(i) : first.clone();
          if (c && c.isObject3D) { if (!make) c.userData.introduced = false; copies.push(c); }
        }
        const parent = first.parent || world;
        const center = v3(o.center || [0, 0, 0]);
        const g = new T.Group();
        g.position.copy(center); g.userData = { noIntro: true, introduced: true };
        if (o.name) g.name = o.name;
        parent.add(g);
        const axis = AX[o.around], spread = (o.spread ?? 360) * DEG, full = spread >= 2 * Math.PI - 1e-6;
        const curve = o.along && o.along.length > 1 ? new T.CatmullRomCurve3(o.along.map(v3)) : null;
        const step = v3(o.step || [0, 0, 0]);
        copies.forEach((c, i) => {
          const rel = curve ? curve.getPointAt(n > 1 ? i / (n - 1) : 0).sub(center) : c.position.clone().sub(center);
          if (axis) {
            const q = new T.Quaternion().setFromAxisAngle(axis, (o.phase ?? 0) * DEG + (full ? i * spread / n : (n > 1 ? i * spread / (n - 1) : 0)));
            rel.applyQuaternion(q); c.quaternion.premultiply(q);
          }
          if (grid) rel.add(new T.Vector3(step.x * (i % grid[0]), step.y * (Math.floor(i / grid[0]) % (grid[1] || 1)), step.z * Math.floor(i / (grid[0] * (grid[1] || 1)))));
          else if (!curve) rel.addScaledVector(step, i);
          if (o.taper != null && n > 1) c.scale.multiplyScalar(1 + (o.taper - 1) * i / (n - 1));
          c.position.copy(rel);
          g.add(c);
        });
        buildIn(copies, 0, 0.03);
        return g;
      },
      /** Slice a part open (the half facing the camera goes) and fill the cut faces, like a cross-section. */
      cut(obj, o = {}) { return cutPart(obj, o, o.fill !== false); },
      /** Open a hollow shell (body, case, building) to look at what's inside. */
      cutaway(obj, o = {}) { return cutPart(obj, o, false); },
      /** Close a cut again. */
      uncut(obj, o = {}) {
        const k = obj && obj.userData.cut;
        if (!k) return;
        delete obj.userData.cut;
        const finish = () => {
          obj.traverse(m => {
            if (m.userData.helper && m.userData.plane === k.plane) { m.parent && m.parent.remove(m); return; }
            if (!m.material) return;
            (Array.isArray(m.material) ? m.material : [m.material]).forEach(x => { x.clippingPlanes = (x.clippingPlanes || []).filter(p => p !== k.plane); x.needsUpdate = true; });
          });
          k.caps.forEach(c => { capsGroup.remove(c.cap); capList.splice(capList.indexOf(c), 1); });
        };
        if (o.dur === 0) { finish(); return; }
        tween({ dur: o.dur ?? 1.2, delay: o.delay ?? 0 }, (e, u) => { k.setAt(k.at + (k.edge - k.at) * e); if (u >= 1) finish(); });
      },
      /** See through a part's outside (it fades to a ghost) to show what's inside. */
      xray(obj, o = {}) { if (obj) fadeMats(matsOf(obj), o.opacity ?? 0.15, o, meshesOf(obj)); },
      /** Fade a part to an opacity (1 = back to normal). */
      fade(obj, o = {}) { if (obj) fadeMats(matsOf(obj, true), o.to ?? 0.3, o, meshesOf(obj)); },
      hide(obj, o = {}) { if (obj) fadeMats(matsOf(obj, true), 0, { ...o, done: () => { obj.visible = false; } }, meshesOf(obj)); },
      show(obj, o = {}) { if (!obj) return; obj.visible = true; fadeMats(matsOf(obj, true), 1, o, meshesOf(obj)); },
      /** Dim everything except this part and zoom to it. kit.isolate() brings everything back. */
      isolate(obj, o = {}) {
        const others = [];
        world.traverse(m => { if (m.isMesh && !m.userData.helper && !m.userData.isGround && (!obj || (!isInside(m, obj) && !isInside(obj, m)))) others.push(m); });
        const mats = new Set(); others.forEach(m => (Array.isArray(m.material) ? m.material : [m.material]).forEach(x => x && mats.add(x)));
        if (obj) matsOf(obj).forEach(x => mats.delete(x));
        fadeMats([...mats], obj ? (o.opacity ?? 0.12) : 1, o, others);
        if (obj) { const mine = matsOf(obj); fadeMats(mine, 1, o); kit.focus(obj, o); } else fit();
      },
      /** Pull a group's parts apart (an exploded view). axis: 'y' stacks them apart along that axis (layers, floors). */
      explode(obj, o = {}) {
        const g = obj || world;
        const kids = g.children.filter(c => !c.userData.isGround && !c.userData.helper && !c.isLineSegments);
        if (kids.length < 2) return;
        kids.forEach(settle);
        const gb = boxOf(g), gc = gb.getCenter(new T.Vector3()), size = gb.getSize(new T.Vector3()).length();
        const k = o.distance ?? 0.8, ax = AX[o.axis];
        const order = ax ? kids.slice().sort((p, q) => boxOf(p).getCenter(new T.Vector3()).dot(ax) - boxOf(q).getCenter(new T.Vector3()).dot(ax)) : kids;
        const dur = o.dur ?? 1.4;
        kids.forEach((c, i) => {
          if (!c.userData.home) c.userData.home = c.position.clone();
          const off = ax ? ax.clone().multiplyScalar((order.indexOf(c) - (kids.length - 1) / 2) * (o.gap ?? size * 0.3 * k))
                         : boxOf(c).getCenter(new T.Vector3()).sub(gc).multiplyScalar(k);
          c.parent.updateWorldMatrix(true, false);
          const offL = c.parent.worldToLocal(gc.clone().add(off)).sub(c.parent.worldToLocal(gc.clone()));
          const from = c.position.clone(), to = c.userData.home.clone().add(offL);
          tween({ dur, delay: (o.delay ?? 0) + i * (o.stagger ?? 0.06) }, e => c.position.lerpVectors(from, to, e));
        });
        kit.after((o.delay ?? 0) + dur * 0.6, fit);
      },
      /** Put exploded parts back together. */
      assemble(obj, o = {}) {
        const g = obj || world;
        g.children.filter(c => c.userData.home).forEach((c, i) => {
          const from = c.position.clone(), to = c.userData.home.clone();
          tween({ dur: o.dur ?? 1.2, delay: (o.delay ?? 0) + i * (o.stagger ?? 0.05) }, e => c.position.lerpVectors(from, to, e));
        });
        kit.after((o.delay ?? 0) + (o.dur ?? 1.2), fit);
      },
      /** Run fn once, sec seconds from now (to sequence things within one step). */
      after(sec, fn) { tween({ delay: sec, dur: 0.001 }, (e, u) => { if (u >= 1) fn(); }); },
      /** Fade out callout tags: all of them (a whole new topic), or 'temp' for just this moment's notes. */
      clearLabels(which) { labels.filter(L => which !== 'temp' || L.temp).forEach(L => fadeLabel(L)); },
      /** Find a part made with name: '…' (also from earlier steps). */
      get(name) { return world.getObjectByName(name); },
      /** Remove a part (or a label returned by kit.label). */
      remove(obj) {
        if (!obj) return;
        if (obj.tag) { obj.tag.remove(); obj.line.remove(); obj.dot.remove(); const i = labels.indexOf(obj); if (i >= 0) labels.splice(i, 1); return; }
        if (obj.userData && obj.userData.cut) kit.uncut(obj, { dur: 0 });
        obj.parent && obj.parent.remove(obj);
      },
      /** Make a part glow and pulse for a few seconds ("this chip here"). */
      highlight(obj, o = {}) {
        if (!obj) return;
        const col = color(o.color || 'yellow'), start = clock, dur = o.dur ?? 3;
        const mats = [];
        obj.traverse(m => { if (m.isMesh && m.material && m.material.emissive) mats.push([m.material, m.material.emissive.clone(), m.material.emissiveIntensity]); });
        anims.push(t => {
          const u = (t - start) / dur;
          for (const [m, e0, i0] of mats) {
            if (u >= 1) { m.emissive.copy(e0); m.emissiveIntensity = i0; continue; }
            m.emissive.copy(col); m.emissiveIntensity = 0.25 + 0.35 * (0.5 + 0.5 * Math.sin((t - start) * 6));
          }
        });
      },
      /** Smoothly zoom the camera onto a part; kit.focus() with no part shows everything again. */
      focus(obj, o = {}) {
        if (obj && !obj.isObject3D && !Array.isArray(obj) && typeof obj === 'object') { o = obj; obj = obj.part || obj.on || null; }   // focus({zoom})
        o = o || {};
        if (o.view) kit.view(o.view, { dur: o.dur });
        if (!obj) { fit(); return; }
        const whole = contentBox();
        if (whole.isEmpty()) return;
        const b = Array.isArray(obj) ? new T.Box3().setFromCenterAndSize(v3(obj), new T.Vector3(0.5, 0.5, 0.5)) : boxOf(obj);
        if (b.isEmpty()) return;
        focused = true; focusCount++;
        // Move most of the way toward the part, but keep enough of the whole model in view for context.
        const wc = whole.getCenter(new T.Vector3()), pc = b.getCenter(new T.Vector3());
        cam.goalTarget.copy(wc.lerp(pc, 0.6));
        const az = camTween ? camTween.az1 : cam.baseAz, el = camTween ? camTween.el1 : cam.el;
        const wholeDist = fitDistance(whole, whole.getCenter(new T.Vector3()), az, el);
        const partDist = Array.isArray(obj) ? wholeDist * 0.5 : fitDistance(b, pc, az, el, obj) * 1.6;
        cam.goalDist = Math.max(partDist / (o.zoom ?? 1), wholeDist * 0.62);
        // Something big in the way (the Sun in front of the Earth)? Swing to the nearest clear angle.
        if (!Array.isArray(obj) && !o.view) {
          const clear = clearAngle(obj, pc, cam.goalTarget, cam.goalDist, az, el);
          if (clear) aimCamera(clear[0], clear[1], o.dur ?? 1.4);
        }
      },
      /** The soft floor shadow under the model: kit.floor(false) for things floating in space or the air. */
      floor(on = true) { floor = !!on; fit(); },
      /** Re-frame to fit everything (after adding parts). */
      fit() { fit(); },
      /** Camera: 'iso' (default), 'side', 'front', 'back', 'top', 'below', or {az, el} in degrees.
          Once the model is on screen the camera glides there (dur seconds). */
      view(name, opt = {}) {
        opt = opt || {};
        if (name && typeof name === 'object') opt = { ...name, ...opt };   // view({az, el, dur})
        if (name !== 'iso' && name != null) viewChosen = true;
        const v = (name && typeof name === 'object') ? [name.az ?? 32, name.el ?? 20]
          : ({ iso: [32, 20], side: [0, 6], front: [90, 8], back: [-90, 8], top: [0, 80], below: [25, -25] }[name] || [32, 20]);
        if (opt.spin) cam.spin = opt.spin === true ? 0.35 : opt.spin;
        if (opt.still) cam.sway = false;
        if (!fitted || opt.dur === 0) { cam.baseAz = cam.az = v[0] * DEG; cam.el = v[1] * DEG; camTween = null; return; }
        let az = v[0] * DEG; while (az - cam.baseAz > Math.PI) az -= 2 * Math.PI; while (az - cam.baseAz < -Math.PI) az += 2 * Math.PI;
        aimCamera(az, v[1] * DEG, opt.dur ?? 1.6);
      },
      /** Swing the camera around the model by deg degrees (el: also tilt to this elevation). */
      orbit(deg = 90, opt = {}) { aimCamera(cam.baseAz + deg * DEG, opt.el != null ? opt.el * DEG : cam.el, opt.dur ?? 2.5); },
      start() {
        fit();
        buildIn(world.children.filter(c => !c.userData.isGround), 0.15);
        requestAnimationFrame(frame);
      },
      /** Run more code in this same scene (a narrated step or a follow-up question). Throws the first error
          after running every statement that works. */
      run(code, note) {
        if (note != null) {
          saveView(curNote);
          // You were looking back at an earlier step: return to where the lesson is before it moves on.
          if (viewingNote != null && viewingNote !== curNote && noteViews[curNote]) showView(noteViews[curNote], 0.7);
          viewingNote = null;
          curNote = note;
        }
        kit.clearLabels('temp');   // a new step (the next sentence): notes about the last moment go
        const errs = runAll(splitStatements(code, true).stmts);
        if (errs.length) throw new Error(errs[0]);
      },
      /** Show narrated step `note` again (its line in the notes was clicked): the camera glides back to
          where it was for that step, its moment notes come back, and the part labels it added flash. */
      revisit(note) {
        if (note == null) return;
        saveView(curNote);
        const v = noteViews[note];
        if (v) showView(v, 1.2);
        viewingNote = note;
        kit.clearLabels('temp');
        for (const [text, o] of noteTemps[note] || []) kit.label(text, { ...o, temp: true, _note: note });
        for (const L of labels) {
          if (L.note !== note || L.temp || L.gone) continue;
          L.tag.classList.remove('flash'); void L.tag.offsetWidth; L.tag.classList.add('flash');
        }
      },
      /** For code that arrives in pieces: feed(text) runs each statement once it's complete; end() runs the
          rest and returns the errors (statements that failed are skipped, the others still run). */
      writer() {
        let buf = '', errs = [];
        return {
          feed(text) { building = true; buf += text; const r = splitStatements(buf, false); buf = r.rest; if (r.stmts.length) errs.push(...runAll(r.stmts)); },
          end() {
            const r = splitStatements(buf, true); buf = '';
            if (r.stmts.length) errs.push(...runAll(r.stmts));
            building = false;
            if (!focused) fit();                         // final framing, now that the whole model is known
            const e = errs; errs = []; return e;
          },
        };
      },
    };

    // ---------- ready-made parts (detailed pieces the model can drop in with one line) ----------
    const css = c => '#' + color(c).getHexString();
    function sub(g, geo, mo, pos, opt = {}) {   // one mesh inside a part's group
      const m = new T.Mesh(geo, mo && mo.isMaterial ? mo : material(mo || {}));
      if (pos) m.position.set(pos[0] || 0, pos[1] || 0, pos[2] || 0);
      m.castShadow = m.receiveShadow = true;
      if (opt.edges) m.add(new T.LineSegments(new T.EdgesGeometry(geo, opt.edgeAngle || 30),
        new T.LineBasicMaterial({ color: 0x1b1e24, transparent: true, opacity: 0.18 })));
      if (opt.name) m.name = opt.name;
      g.add(m);
      return m;
    }
    const finishPart = (g, o) => place(g, { ...o, edges: false });
    // Turn a part built along Y so its axis is X or Z (children move, the group itself stays unrotated so kit.spin works).
    function orientKids(g, axis) {
      const q = axis === 'x' ? new T.Quaternion().setFromAxisAngle(AX.z, -Math.PI / 2)
              : axis === 'z' ? new T.Quaternion().setFromAxisAngle(AX.x, Math.PI / 2) : null;
      if (q) g.children.forEach(c => { c.position.applyQuaternion(q); c.quaternion.premultiply(q); });
      return g;
    }
    function mergeGeos(list) {
      const geos = list.map(g => g.index ? g.toNonIndexed() : g);
      const out = new T.BufferGeometry();
      for (const n of ['position', 'normal', 'uv']) {
        if (!geos.every(g => g.attributes[n])) continue;
        const size = geos[0].attributes[n].itemSize, arr = new Float32Array(geos.reduce((s, g) => s + g.attributes[n].array.length, 0));
        let off = 0; for (const g of geos) { arr.set(g.attributes[n].array, off); off += g.attributes[n].array.length; }
        out.setAttribute(n, new T.BufferAttribute(arr, size));
      }
      return out;
    }
    function textTexture(str, o = {}) {
      const lines = String(str ?? '').split('\n'), fs = 72;
      const font = `${o.weight || 700} ${fs}px ${o.font || '-apple-system, "Helvetica Neue", Arial, sans-serif'}`;
      const cv = document.createElement('canvas'), g = cv.getContext('2d');
      g.font = font;
      const w = Math.ceil(Math.max(1, ...lines.map(l => g.measureText(l).width))) + 24, h = Math.ceil(lines.length * fs * 1.18) + 12;
      cv.width = w; cv.height = h;
      if (o.bg) { g.fillStyle = css(o.bg); g.fillRect(0, 0, w, h); }
      g.font = font; g.fillStyle = css(o.color || '#2a2d33'); g.textAlign = 'center'; g.textBaseline = 'middle';
      lines.forEach((l, i) => g.fillText(l, w / 2, 6 + fs * 1.18 * (i + 0.5)));
      const t = new T.CanvasTexture(cv); t.colorSpace = T.SRGBColorSpace; t.anisotropy = 4;
      return { t, aspect: w / h };
    }
    // Seeded 3D value noise (for planets, rocks, terrain-like textures).
    function noise3(seed = 1) {
      const hash = (x, y, z) => { let h = (x * 374761393 + y * 668265263 + z * 1274126177 + seed * 1442695041) | 0; h = (h ^ (h >>> 13)) * 1274126177 | 0; return ((h ^ (h >>> 16)) >>> 0) / 4294967296; };
      const sm = t => t * t * (3 - 2 * t), L = (a, b, t) => a + (b - a) * t;
      const n = (x, y, z) => {
        const xi = Math.floor(x), yi = Math.floor(y), zi = Math.floor(z), u = sm(x - xi), v = sm(y - yi), w = sm(z - zi);
        return L(L(L(hash(xi, yi, zi), hash(xi + 1, yi, zi), u), L(hash(xi, yi + 1, zi), hash(xi + 1, yi + 1, zi), u), v),
                 L(L(hash(xi, yi, zi + 1), hash(xi + 1, yi, zi + 1), u), L(hash(xi, yi + 1, zi + 1), hash(xi + 1, yi + 1, zi + 1), u), v), w);
      };
      return (x, y, z, oct = 5) => { let s = 0, a = 0.5, f = 1; for (let i = 0; i < oct; i++) { s += a * n(x * f, y * f, z * f); f *= 2.03; a *= 0.5; } return s / (1 - Math.pow(0.5, oct)); };
    }
    // Smooth organic shapes: a signed-distance blend of spheres and capsules, meshed with surface nets.
    function blobMesh(o) {
      const prims = (o.parts || [{ at: [0, 0, 0], r: 0.5 }]).map(p => {
        if (Array.isArray(p)) p = { at: p, r: 0.4 };
        if (p.from && p.to) {
          const [r0, r1] = Array.isArray(p.r) ? p.r : [p.r ?? 0.3, p.r ?? 0.3];
          return { cap: true, a: v3(p.from), b: v3(p.to), r0, r1, cut: !!p.cut, col: p.color, R: Math.max(r0, r1) };
        }
        const r = p.r ?? 0.5, s = p.stretch ? v3(p.stretch) : new T.Vector3(1, 1, 1);
        return { c: v3(p.at || [0, 0, 0]), r, s, cut: !!p.cut, col: p.color, R: r * Math.max(s.x, s.y, s.z) };
      });
      const solid = prims.filter(p => !p.cut), cuts = prims.filter(p => p.cut);
      if (!solid.length) return null;
      const avgR = solid.reduce((s, p) => s + p.R, 0) / solid.length;
      const k = Math.max(1e-4, o.smooth ?? avgR * 0.5);
      const P = new T.Vector3(), Q = new T.Vector3(), BA = new T.Vector3();
      const dist = (p, x, y, z) => {
        P.set(x, y, z);
        if (p.cap) {
          Q.copy(P).sub(p.a); BA.copy(p.b).sub(p.a);
          const h = Math.max(0, Math.min(1, Q.dot(BA) / Math.max(1e-9, BA.lengthSq())));
          return Q.sub(BA.multiplyScalar(h)).length() - (p.r0 + (p.r1 - p.r0) * h);
        }
        Q.copy(P).sub(p.c).divide(p.s).divideScalar(p.r);
        return (Q.length() - 1) * p.r * Math.min(p.s.x, p.s.y, p.s.z);
      };
      const smin = (a, b) => { const h = Math.max(k - Math.abs(a - b), 0) / k; return Math.min(a, b) - h * h * k * 0.25; };
      const f = (x, y, z) => {
        let d = dist(solid[0], x, y, z);
        for (let i = 1; i < solid.length; i++) d = smin(d, dist(solid[i], x, y, z));
        for (const c of cuts) d = -smin(-d, dist(c, x, y, z));
        return d;
      };
      const lo = new T.Vector3(Infinity, Infinity, Infinity), hi = lo.clone().negate();
      for (const p of solid) {
        const pts = p.cap ? [p.a, p.b] : [p.c];
        for (const c of pts) { lo.min(c.clone().subScalar(p.R)); hi.max(c.clone().addScalar(p.R)); }
      }
      lo.subScalar(k * 0.5 + avgR * 0.15); hi.addScalar(k * 0.5 + avgR * 0.15);
      const size = hi.clone().sub(lo), step = Math.max(size.x, size.y, size.z) / Math.min(96, Math.max(16, o.res ?? 52));
      const nx = Math.ceil(size.x / step) + 2, ny = Math.ceil(size.y / step) + 2, nz = Math.ceil(size.z / step) + 2;
      const val = new Float32Array(nx * ny * nz), id = (x, y, z) => x + nx * (y + ny * z);
      for (let z = 0; z < nz; z++) for (let y = 0; y < ny; y++) for (let x = 0; x < nx; x++)
        val[id(x, y, z)] = (x === 0 || y === 0 || z === 0 || x === nx - 1 || y === ny - 1 || z === nz - 1) ? 1
          : f(lo.x + x * step, lo.y + y * step, lo.z + z * step);
      const cx = nx - 1, cy = ny - 1, cid = (x, y, z) => x + cx * (y + cy * z);
      const cell = new Int32Array(cx * cy * (nz - 1)).fill(-1), pos = [];
      const C = [[0, 0, 0], [1, 0, 0], [0, 1, 0], [1, 1, 0], [0, 0, 1], [1, 0, 1], [0, 1, 1], [1, 1, 1]];
      const E = [[0, 1], [2, 3], [4, 5], [6, 7], [0, 2], [1, 3], [4, 6], [5, 7], [0, 4], [1, 5], [2, 6], [3, 7]];
      const vs = new Float32Array(8);
      for (let z = 0; z < nz - 1; z++) for (let y = 0; y < ny - 1; y++) for (let x = 0; x < nx - 1; x++) {
        let mask = 0;
        for (let c = 0; c < 8; c++) { vs[c] = val[id(x + C[c][0], y + C[c][1], z + C[c][2])]; if (vs[c] < 0) mask |= 1 << c; }
        if (mask === 0 || mask === 255) continue;
        let px = 0, py = 0, pz = 0, n = 0;
        for (const [a, b] of E) {
          if ((vs[a] < 0) === (vs[b] < 0)) continue;
          const t = vs[a] / (vs[a] - vs[b]);
          px += C[a][0] + (C[b][0] - C[a][0]) * t; py += C[a][1] + (C[b][1] - C[a][1]) * t; pz += C[a][2] + (C[b][2] - C[a][2]) * t; n++;
        }
        cell[cid(x, y, z)] = pos.length / 3;
        pos.push(lo.x + (x + px / n) * step, lo.y + (y + py / n) * step, lo.z + (z + pz / n) * step);
      }
      const index = [], A = new T.Vector3(), B = new T.Vector3(), Cc = new T.Vector3(), N = new T.Vector3();
      const quad = (q, dir) => {
        if (q.some(i => i < 0)) return;
        const at = i => new T.Vector3(pos[3 * i], pos[3 * i + 1], pos[3 * i + 2]);
        A.copy(at(q[0])); B.copy(at(q[1])).sub(A); Cc.copy(at(q[2])).sub(A); N.crossVectors(B, Cc);
        if (N.dot(dir) < 0) q.reverse();
        index.push(q[0], q[1], q[2], q[0], q[2], q[3]);
      };
      for (let z = 0; z < nz - 1; z++) for (let y = 0; y < ny - 1; y++) for (let x = 0; x < nx - 1; x++) {
        const v0 = val[id(x, y, z)] < 0;
        const s = v0 ? 1 : -1;
        if (y > 0 && z > 0 && (val[id(x + 1, y, z)] < 0) !== v0)
          quad([cell[cid(x, y - 1, z - 1)], cell[cid(x, y, z - 1)], cell[cid(x, y, z)], cell[cid(x, y - 1, z)]], new T.Vector3(s, 0, 0));
        if (x > 0 && z > 0 && (val[id(x, y + 1, z)] < 0) !== v0)
          quad([cell[cid(x - 1, y, z - 1)], cell[cid(x, y, z - 1)], cell[cid(x, y, z)], cell[cid(x - 1, y, z)]], new T.Vector3(0, s, 0));
        if (x > 0 && y > 0 && (val[id(x, y, z + 1)] < 0) !== v0)
          quad([cell[cid(x - 1, y - 1, z)], cell[cid(x, y - 1, z)], cell[cid(x, y, z)], cell[cid(x - 1, y, z)]], new T.Vector3(0, 0, s));
      }
      // Pull each vertex onto the surface and shade by the field's gradient (smooth, no facets).
      const nor = new Float32Array(pos.length), e = step * 0.5, cols = [];
      const tints = prims.some(p => p.col) ? solid.map(p => color(p.col || o.color)) : null, base = color(o.color || 'light');
      for (let i = 0; i < pos.length; i += 3) {
        let x = pos[i], y = pos[i + 1], z = pos[i + 2];
        for (let it = 0; it < 2; it++) {
          const gx = f(x + e, y, z) - f(x - e, y, z), gy = f(x, y + e, z) - f(x, y - e, z), gz = f(x, y, z + e) - f(x, y, z - e);
          const gl = Math.hypot(gx, gy, gz) / (2 * e) || 1, d = f(x, y, z);
          x -= d * gx / (2 * e) / (gl * gl); y -= d * gy / (2 * e) / (gl * gl); z -= d * gz / (2 * e) / (gl * gl);
        }
        pos[i] = x; pos[i + 1] = y; pos[i + 2] = z;
        const gx = f(x + e, y, z) - f(x - e, y, z), gy = f(x, y + e, z) - f(x, y - e, z), gz = f(x, y, z + e) - f(x, y, z - e), gl = Math.hypot(gx, gy, gz) || 1;
        nor[i] = gx / gl; nor[i + 1] = gy / gl; nor[i + 2] = gz / gl;
        if (tints) {
          const c = new T.Color(0, 0, 0), ds = solid.map(p => dist(p, x, y, z)), dm = Math.min(...ds), sc = k * 0.12 + avgR * 0.02;
          let ws = 0;
          solid.forEach((p, j) => { const w = Math.exp(-(ds[j] - dm) / sc); c.r += tints[j].r * w; c.g += tints[j].g * w; c.b += tints[j].b * w; ws += w; });
          cols.push(c.r / ws, c.g / ws, c.b / ws);
        }
      }
      const geo = new T.BufferGeometry();
      geo.setAttribute('position', new T.Float32BufferAttribute(pos, 3));
      geo.setAttribute('normal', new T.Float32BufferAttribute(nor, 3));
      if (tints) geo.setAttribute('color', new T.Float32BufferAttribute(cols, 3));
      geo.setIndex(index);
      const m = new T.Mesh(geo, material({ ...o, color: tints ? '#ffffff' : o.color, rough: o.rough ?? 0.5 }));
      if (tints) { m.material.vertexColors = true; m.userData.capColor = base.clone(); }
      if (!tints && base) m.material.color.copy(base);
      return m;
    }
    const ELEMENTS = {   // ball radius (Å, ball-and-stick), CPK color
      H: [0.31, '#f2f2f2'], C: [0.42, '#3d4148'], N: [0.42, '#3b6ef6'], O: [0.42, '#e5484d'], S: [0.5, '#e0c020'], P: [0.5, '#f76b15'],
      F: [0.38, '#2fa36b'], Cl: [0.48, '#2fa36b'], Br: [0.52, '#a52a2a'], I: [0.58, '#8e4ec6'], Na: [0.6, '#8e4ec6'], K: [0.66, '#8e4ec6'],
      Mg: [0.55, '#2f8f5b'], Ca: [0.62, '#7f8a96'], Fe: [0.55, '#e07a30'], Cu: [0.52, '#c27a3a'], Zn: [0.52, '#7d80b0'], Si: [0.5, '#d4b68a'],
    };
    const MOLECULES = {
      water: { atoms: [['O', [0, 0, 0]], ['H', [0.757, 0.586, 0]], ['H', [-0.757, 0.586, 0]]] },
      co2: { atoms: [['C', [0, 0, 0]], ['O', [1.16, 0, 0]], ['O', [-1.16, 0, 0]]], bonds: [[0, 1, 2], [0, 2, 2]] },
      methane: { atoms: [['C', [0, 0, 0]], ['H', [0.63, 0.63, 0.63]], ['H', [-0.63, -0.63, 0.63]], ['H', [-0.63, 0.63, -0.63]], ['H', [0.63, -0.63, -0.63]]] },
      ammonia: { atoms: [['N', [0, 0, 0]], ['H', [0.94, -0.38, 0]], ['H', [-0.47, -0.38, 0.814]], ['H', [-0.47, -0.38, -0.814]]] },
      oxygen: { atoms: [['O', [-0.6, 0, 0]], ['O', [0.6, 0, 0]]], bonds: [[0, 1, 2]] },
      nitrogen: { atoms: [['N', [-0.55, 0, 0]], ['N', [0.55, 0, 0]]], bonds: [[0, 1, 3]] },
      hydrogen: { atoms: [['H', [-0.37, 0, 0]], ['H', [0.37, 0, 0]]] },
      ethanol: { atoms: [['C', [-1.17, -0.4, 0]], ['C', [0.17, 0.3, 0]], ['O', [1.2, -0.65, 0]], ['H', [-1.98, 0.33, 0]], ['H', [-1.26, -1.03, 0.89]], ['H', [-1.26, -1.03, -0.89]],
        ['H', [0.26, 0.94, 0.89]], ['H', [0.26, 0.94, -0.89]], ['H', [2.05, -0.2, 0]]] },
      benzene: (() => {
        const atoms = [], bonds = [];
        for (let i = 0; i < 6; i++) { const a = i * Math.PI / 3; atoms.push(['C', [1.39 * Math.cos(a), 0, 1.39 * Math.sin(a)]]); }
        for (let i = 0; i < 6; i++) { const a = i * Math.PI / 3; atoms.push(['H', [2.48 * Math.cos(a), 0, 2.48 * Math.sin(a)]]); bonds.push([i, (i + 1) % 6, i % 2 ? 1 : 2], [i, i + 6, 1]); }
        return { atoms, bonds };
      })(),
    };

    // Theo Jansen's Strandbeest leg: his eleven "holy numbers" (cm). The crank turns at O, the frame pivot is P,
    // two rigid triangles (P-B-D, C-E-F), and the foot F walks a flat-bottomed path.
    const JANSEN = size => {
      const [a, b, c, d, e, f, g, h, i, j, k, l, m] = [38, 41.5, 39.3, 40.1, 55.8, 39.4, 36.7, 65.7, 49, 50, 61.9, 7.8, 15];
      return { unit: size / 120, fixed: { O: [0, 0], P: [-a, -l] }, crank: { name: 'A', around: 'O', r: m },
        joints: { B: { from: ['A', 'P'], len: [j, b], side: 'up' }, C: { from: ['A', 'P'], len: [k, c], side: 'down' },
                  D: { from: ['B', 'P'], len: [e, d], side: 'left' }, E: { from: ['D', 'C'], len: [f, g], side: 'left' },
                  F: { from: ['E', 'C'], len: [h, i], side: 'down' } },
        bars: [['O', 'A'], ['A', 'B'], ['A', 'C'], ['P', 'C'], ['D', 'E']],
        plates: [['P', 'B', 'D'], ['C', 'E', 'F']], trace: 'F' };
    };

    Object.assign(kit, {
      /** A spur gear. r: pitch radius (two gears mesh when their centers are r1 + r2 apart; give the second
          phase: 0.5 so its teeth slot in, and spin it at -speed * teeth1 / teeth2). Axis default 'z' (face toward you). */
      gear(o = {}) {
        const r = o.r ?? 1, n = Math.max(6, Math.round(o.teeth ?? Math.max(10, r * 18))), th = o.thickness ?? r * 0.22;
        const m = 2 * r / n, ra = r + m, rd = r - 1.2 * m, w = Math.PI / n, ph = (o.phase ?? 0) * 2 * w;
        const sh = new T.Shape(), P = (rr, a) => [rr * Math.cos(a), rr * Math.sin(a)];
        for (let i = 0; i < n; i++) {
          const a = ph + i * 2 * w;
          const pts = [P(rd, a - w * 0.62), P(r * 0.995, a - w * 0.5), P(ra, a - w * 0.26), P(ra, a + w * 0.26), P(r * 0.995, a + w * 0.5), P(rd, a + w * 0.62), P(rd, a + w * 1.38)];
          pts.forEach((p, j) => (i === 0 && j === 0) ? sh.moveTo(...p) : sh.lineTo(...p));
        }
        sh.closePath();
        const hole = o.hole ?? r * 0.18;
        if (hole > 0) { const hp = new T.Path(); hp.absarc(0, 0, hole, 0, 2 * Math.PI, true); sh.holes.push(hp); }
        const spokes = o.spokes ?? (r > 0.6 && n > 20 ? 5 : 0);
        if (spokes) for (let i = 0; i < spokes; i++) {   // lightening holes between the hub and the rim
          const a = (i + 0.5) * 2 * Math.PI / spokes, rr = (hole * 1.6 + rd * 0.78) / 2, wr = (rd * 0.78 - hole * 1.6) / 2;
          if (wr <= 0) break;
          const hp = new T.Path(); hp.absarc(rr * Math.cos(a), rr * Math.sin(a), Math.min(wr, rr * Math.sin(Math.PI / spokes) * 0.7), 0, 2 * Math.PI, true); sh.holes.push(hp);
        }
        const geo = new T.ExtrudeGeometry(sh, { depth: th, bevelEnabled: true, bevelThickness: th * 0.08, bevelSize: m * 0.08, bevelSegments: 1, curveSegments: 18 });
        geo.translate(0, 0, -th / 2); geo.rotateX(-Math.PI / 2);
        const g = new T.Group();
        sub(g, geo, { color: o.color || 'metal', metal: o.metal ?? true }, null, { edges: true, edgeAngle: 40 });
        if (hole > 0 && o.shaft !== false) sub(g, new T.CylinderGeometry(hole * 0.98, hole * 0.98, th * (o.shaftLength ?? 2.4), 24), { color: 'dark', metal: true });
        g.userData.pitch = r; g.userData.teeth = n;
        return finishPart(orientKids(g, o.axis || 'z'), o);
      },
      /** Bladed rotor: kind 'fan' (jet engine fan), 'turbine' / 'compressor' (many short blades), 'propeller',
          'wind' (wind turbine), 'pc' (computer fan). r: tip radius. Axis default 'x', front (spinner) toward +x. kit.spin(it, axis, speed) turns it. */
      rotor(o = {}) {
        const kind = o.kind || 'fan';
        const K = { fan: [18, 0.3, 0.34, 38, 30, 0.18], turbine: [30, 0.62, 0.2, 18, 42, 0], compressor: [30, 0.55, 0.22, 20, 40, 0],
                    propeller: [3, 0.12, 0.24, 32, 22, 0.1], wind: [3, 0.05, 0.08, 22, 8, 0], pc: [7, 0.4, 0.55, 10, 30, 0.35] }[kind] || [12, 0.3, 0.3, 30, 30, 0.1];
        const R = o.r ?? 1, n = Math.max(1, Math.round(o.count ?? K[0])), hubR = R * (o.hub ?? K[1]), chord = R * (o.chord ?? K[2]);
        const twist = (o.twist ?? K[3]) * DEG, pitch = (o.pitch ?? K[4]) * DEG, sweep = R * (o.sweep ?? K[5]);
        const ns = 14, nt = 8, span = R - hubR, thick = chord * 0.09;
        const top = [], bot = [];
        for (let i = 0; i <= ns; i++) {
          const s = i / ns, rr = hubR * 0.92 + (span + hubR * 0.08) * s;
          const c = chord * (kind === 'wind' ? 1.3 - 0.95 * s : kind === 'propeller' ? 0.7 + 0.6 * Math.sin(Math.PI * Math.min(1, s * 1.15)) - 0.35 * s : 1 - 0.25 * s);
          const ang = pitch + twist * (1 - s), sw = sweep * s * s;
          for (let j = 0; j <= nt; j++) {
            const t = j / nt - 0.5, camber = c * 0.06 * (1 - 4 * t * t), half = thick * (1 - s * 0.5) * Math.sqrt(Math.max(0, 1 - 4 * t * t));
            // chord runs around the rotor (z) tilted toward the axis (y) by ang
            const cz = t * c, along = [0, Math.sin(ang) * cz, Math.cos(ang) * cz + sw], nrm = [0, Math.cos(ang), -Math.sin(ang)];
            top.push(rr, along[1] + nrm[1] * (camber + half), along[2] + nrm[2] * (camber + half));
            bot.push(rr, along[1] + nrm[1] * (camber - half), along[2] + nrm[2] * (camber - half));
          }
        }
        const pos = [...top, ...bot], idx = [], off = top.length / 3, row = nt + 1;
        for (let i = 0; i < ns; i++) for (let j = 0; j < nt; j++) {
          const a = i * row + j, b = a + row;
          idx.push(a, b, a + 1, a + 1, b, b + 1);
          idx.push(off + a, off + a + 1, off + b, off + a + 1, off + b + 1, off + b);
        }
        for (let j = 0; j < nt; j++) { const a = ns * row + j; idx.push(a, a + 1, off + a, a + 1, off + a + 1, off + a); }   // close the tip
        const bg = new T.BufferGeometry();
        bg.setAttribute('position', new T.Float32BufferAttribute(pos, 3)); bg.setIndex(idx); bg.computeVertexNormals();
        const g = new T.Group(), bm = material({ color: o.color || (kind === 'wind' ? 'white' : 'metal'), metal: kind !== 'wind' && kind !== 'pc' });
        if (kind === 'pc') bm.color.copy(color(o.color || 'dark'));
        for (let i = 0; i < n; i++) { const b = sub(g, bg, bm); b.rotation.y = i * 2 * Math.PI / n; b.userData.blade = true; }
        const hubLen = Math.max(chord * 0.9, R * 0.12), hc = o.hubColor || (kind === 'pc' ? 'dark' : 'metal');
        sub(g, new T.CylinderGeometry(hubR, hubR, hubLen, 40), { color: hc, metal: true });
        if (o.spinner ?? (kind === 'fan' || kind === 'propeller' || kind === 'wind')) {
          const sp = new T.LatheGeometry([0, 0.35, 0.65, 0.85, 1].map(u => new T.Vector2(Math.max(0.001, hubR * Math.sqrt(1 - u * u)), hubLen / 2 + u * hubR * (kind === 'wind' ? 1.2 : 1.6))), 40);
          sub(g, sp, { color: o.spinnerColor || (kind === 'fan' ? 'dark' : hc), metal: true });
        }
        if (o.ring ?? kind === 'pc') sub(g, new T.CylinderGeometry(R * 1.04, R * 1.04, hubLen * 1.2, 64, 1, true), { color: o.ringColor || 'dark' });
        return finishPart(orientKids(g, o.axis || 'x'), o);
      },
      /** A coil spring from at (bottom) up h along the axis (default 'y'). */
      spring(o = {}) {
        const r = o.r ?? 0.3, h = o.h ?? 1, coils = o.coils ?? 8, wire = o.wire ?? r * 0.12, pts = [];
        for (let i = 0; i <= coils * 24; i++) { const a = i / 24 * 2 * Math.PI; pts.push(new T.Vector3(r * Math.cos(a), h * i / (coils * 24), r * Math.sin(a))); }
        const g = new T.Group();
        sub(g, new T.TubeGeometry(new T.CatmullRomCurve3(pts), coils * 24, wire, 10), { color: o.color || 'metal', metal: true });
        return finishPart(orientKids(g, o.axis || 'y'), o);
      },
      /** A screw or bolt: the head sits at at, the threaded shaft goes down (−y) by length. head: 'hex', 'round', 'flat'. */
      screw(o = {}) {
        const r = o.r ?? 0.1, L = o.length ?? r * 8, head = o.head || 'hex', g = new T.Group(), mat = { color: o.color || 'metal', metal: true };
        if (head === 'hex') sub(g, new T.CylinderGeometry(r * 1.8, r * 1.8, r * 1.3, 6), mat, [0, r * 0.65, 0], { edges: true });
        else if (head === 'flat') sub(g, new T.CylinderGeometry(r * 1.9, r, r * 0.9, 32), mat, [0, -r * 0.45 + r * 0.9, 0]);
        else sub(g, new T.SphereGeometry(r * 1.8, 28, 12, 0, 2 * Math.PI, 0, Math.PI / 2).scale(1, 0.6, 1), mat);
        if (head !== 'hex') sub(g, new T.BoxGeometry(r * 2.6, r * 0.5, r * 0.35), { color: 'dark' }, [0, head === 'flat' ? r * 0.75 : r * 1.0, 0]);
        sub(g, new T.CylinderGeometry(r * 0.85, r * 0.6, L, 24), mat, [0, -L / 2, 0]);
        const pts = [], turns = L / (r * 0.7);
        for (let i = 0; i <= turns * 16; i++) { const a = i / 16 * 2 * Math.PI, y = -r * 0.3 - (L - r * 0.8) * i / (turns * 16); pts.push(new T.Vector3(r * 0.9 * Math.cos(a), y, r * 0.9 * Math.sin(a))); }
        if (pts.length > 4) sub(g, new T.TubeGeometry(new T.CatmullRomCurve3(pts), pts.length, r * 0.14, 6), mat);
        return finishPart(g, o);
      },
      /** Printed text on a flat card (chip markings, signs, a name on a part). plane: 'xz' lies flat facing up
          (default), 'xy' faces +z, 'yz' faces +x. size: letter height. */
      text(str, o = {}) {
        if (str && typeof str === 'object' && !Array.isArray(str)) { o = str; str = o.text; }
        const { t, aspect } = textTexture(str, o), hgt = (o.size ?? 0.3) * (String(str ?? '').split('\n').length * 1.18 + 0.17);
        const geo = new T.PlaneGeometry(hgt * aspect, hgt);
        if ((o.plane || 'xz') === 'xz') geo.rotateX(-Math.PI / 2); else if (o.plane === 'yz') geo.rotateY(Math.PI / 2);
        const mat = new T.MeshStandardMaterial({ map: t, transparent: !o.bg, roughness: 0.7, depthWrite: !!o.bg, side: T.DoubleSide,
          polygonOffset: true, polygonOffsetFactor: -2, polygonOffsetUnits: -2 });
        const m = new T.Mesh(geo, mat); m.userData.decal = true;
        return place(m, { ...o, edges: false });
      },
      /** A circuit board with traces, mounting holes and rounded corners. size [width x, depth z] (cm by default:
          a Raspberry Pi is [8.5, 5.6]). Its bottom sits at at; the top is at y = thickness. */
      board(o = {}) {
        const [w, d] = o.size || [8.5, 5.6], th = o.thickness ?? Math.min(w, d) * 0.028, rc = Math.min(w, d) * 0.06;
        const sh = new T.Shape(), x = w / 2, y = d / 2;
        sh.moveTo(-x + rc, -y); sh.lineTo(x - rc, -y); sh.quadraticCurveTo(x, -y, x, -y + rc); sh.lineTo(x, y - rc); sh.quadraticCurveTo(x, y, x - rc, y);
        sh.lineTo(-x + rc, y); sh.quadraticCurveTo(-x, y, -x, y - rc); sh.lineTo(-x, -y + rc); sh.quadraticCurveTo(-x, -y, -x + rc, -y);
        const hr = Math.min(w, d) * 0.025, inset = Math.min(w, d) * 0.062, holes = o.holes === false ? [] : [[-x + inset, -y + inset], [x - inset, -y + inset], [-x + inset, y - inset], [x - inset, y - inset]];
        holes.forEach(([hx, hy]) => { const p = new T.Path(); p.absarc(hx, hy, hr, 0, 2 * Math.PI, true); sh.holes.push(p); });
        const geo = new T.ExtrudeGeometry(sh, { depth: th, bevelEnabled: false, curveSegments: 10 });
        geo.rotateX(-Math.PI / 2);
        // Traces: thin lighter lines on the top, made once per board.
        const cv = document.createElement('canvas'); cv.width = 512; cv.height = Math.round(512 * d / w);
        const g2 = cv.getContext('2d'), base = color(o.color || 'pcb');
        g2.fillStyle = '#' + base.getHexString(); g2.fillRect(0, 0, cv.width, cv.height);
        g2.strokeStyle = '#' + base.clone().lerp(new T.Color('#ffffff'), 0.22).getHexString(); g2.lineWidth = 2.2; g2.lineCap = 'round';
        const rnd = (() => { let s = (o.seed ?? 7) * 9301 + 49297; return () => ((s = (s * 9301 + 49297) % 233280) / 233280); })();
        if (o.traces !== false) for (let i = 0; i < 70; i++) {
          let px = rnd() * cv.width, py = rnd() * cv.height; g2.beginPath(); g2.moveTo(px, py);
          for (let j = 0; j < 3; j++) { if (j % 2) py += (rnd() - 0.5) * 140; else px += (rnd() - 0.5) * 220; g2.lineTo(px, py); }
          g2.stroke(); g2.fillStyle = g2.strokeStyle; g2.beginPath(); g2.arc(px, py, 3.2, 0, 7); g2.fill();
        }
        const tex = new T.CanvasTexture(cv); tex.colorSpace = T.SRGBColorSpace; tex.repeat.set(1 / w, 1 / d); tex.offset.set(0.5, 0.5);
        const g = new T.Group();
        sub(g, geo, new T.MeshStandardMaterial({ map: tex, roughness: 0.55, metalness: 0.05, side: T.DoubleSide }), null, { edges: true, edgeAngle: 40 });
        holes.forEach(([hx, hy]) => sub(g, new T.TorusGeometry(hr * 1.35, hr * 0.38, 8, 24).rotateX(Math.PI / 2), { color: 'gold', metal: true }, [hx, th + 0.001, -hy]));
        return finishPart(g, o);
      },
      /** A chip package lying on a board. size [x, z], h: height. pins: 'sides' (two long sides), 'quad' (all four),
          'none' / 'bga' (contacts underneath). label: text printed on top. Its bottom sits at at. */
      chip(o = {}) {
        const [w, d] = o.size || [1.4, 1.4], h = o.h ?? Math.min(w, d) * 0.1, g = new T.Group();
        sub(g, roundedBox(w, h, d, h * 0.2), { color: o.color || '#2b2e34', rough: 0.45 }, [0, h * 0.6, 0], { edges: true, edgeAngle: 50 });
        const pins = o.pins || (Math.abs(w - d) < 0.15 * Math.max(w, d) ? 'quad' : 'sides');
        if (pins === 'quad' || pins === 'sides') {
          const pitch = o.pitch ?? Math.max(w, d) / 16, list = [], pl = h * 1.1, pw = pitch * 0.45;
          const sides = pins === 'quad' ? ['+z', '-z', '+x', '-x'] : (w >= d ? ['+z', '-z'] : ['+x', '-x']);
          for (const sd of sides) {
            const alongX = sd[1] === 'z', L = alongX ? w : d, n = Math.max(2, Math.floor((L * 0.86) / pitch));
            for (let i = 0; i < n; i++) {
              const u = (i - (n - 1) / 2) * pitch, sg = sd[0] === '+' ? 1 : -1;
              const geo = alongX ? new T.BoxGeometry(pw, h * 0.18, pl) : new T.BoxGeometry(pl, h * 0.18, pw);
              geo.translate(alongX ? u : sg * (w / 2 + pl * 0.35), h * 0.3, alongX ? sg * (d / 2 + pl * 0.35) : u);
              list.push(geo);
            }
          }
          sub(g, mergeGeos(list), { color: 'metal', metal: true });
        }
        if (o.label) {
          const { t, aspect } = textTexture(o.label, { color: o.labelColor || '#c9ccd2' });
          const lw = Math.min(w * 0.8, d * 0.45 * aspect), geo = new T.PlaneGeometry(lw, lw / aspect).rotateX(-Math.PI / 2);
          const m = sub(g, geo, new T.MeshStandardMaterial({ map: t, transparent: true, depthWrite: false, polygonOffset: true, polygonOffsetFactor: -2, polygonOffsetUnits: -2 }), [0, h * 1.1 + 0.002, 0]);
          m.castShadow = false;
        }
        sub(g, new T.CircleGeometry(Math.min(w, d) * 0.05, 16).rotateX(-Math.PI / 2), { color: '#15171b' }, [-w * 0.36, h * 1.1 + 0.003, d * 0.33]).castShadow = false;
        return finishPart(g, o);
      },
      /** A connector. type: 'usb' (USB-A, stacked: 'usb2'), 'usbc', 'hdmi', 'microhdmi', 'ethernet', 'jack' (audio),
          'header' (pin header along x; count: [columns, rows]), 'sd', 'ribbon' (flat-cable socket), 'power'. face: where the
          opening points ('x' default, '-x', 'z', '-z', 'y'). Sizes are real, in cm (scale: to match other units). Bottom at at. */
      port(o = {}) {
        const type = o.type || 'usb', g = new T.Group(), shell = { color: 'metal', metal: true }, dark = { color: '#1d1f24' };
        // [depth x, height y, width z] in cm; the opening is on the +x face
        const box = (s, mat, at, edges = true) => sub(g, roundedBox(s[0], s[1], s[2], Math.min(...s) * 0.12), mat, at, { edges, edgeAngle: 40 });
        if (type === 'usb' || type === 'usb2') {
          const H = type === 'usb2' ? 1.55 : 0.66, D = 1.4, Wd = 1.32;
          box([D, H, Wd], shell, [0, H / 2, 0]);
          const n = type === 'usb2' ? 2 : 1;
          for (let i = 0; i < n; i++) {
            const y = H * (i + 0.5) / n;
            sub(g, new T.BoxGeometry(0.02, H / n * 0.72, Wd * 0.88), dark, [D / 2 + 0.002, y, 0]);
            sub(g, new T.BoxGeometry(D * 0.5, 0.18, Wd * 0.72), { color: o.color || (n === 2 ? 'blue' : 'white') }, [D * 0.26, y - 0.06, 0]);
          }
        } else if (type === 'usbc' || type === 'microhdmi' || type === 'power') {
          const s = type === 'usbc' ? [0.75, 0.33, 0.9] : type === 'power' ? [0.75, 0.33, 0.9] : [0.75, 0.3, 0.65];
          box(s, shell, [0, s[1] / 2, 0]);
          sub(g, new T.BoxGeometry(0.02, s[1] * 0.6, s[2] * 0.82), dark, [s[0] / 2 + 0.002, s[1] / 2, 0]);
        } else if (type === 'hdmi') {
          const s = [1.1, 0.6, 1.5];
          box(s, shell, [0, s[1] / 2, 0]);
          sub(g, new T.BoxGeometry(0.02, s[1] * 0.62, s[2] * 0.85), dark, [s[0] / 2 + 0.002, s[1] / 2, 0]);
        } else if (type === 'ethernet') {
          const s = [2.1, 1.35, 1.6];
          box(s, shell, [0, s[1] / 2, 0]);
          sub(g, new T.BoxGeometry(0.02, 0.85, 1.15), dark, [s[0] / 2 + 0.002, 0.55, 0]);
          sub(g, new T.BoxGeometry(0.02, 0.22, 0.4), dark, [s[0] / 2 + 0.002, 1.02, 0]);
          [-0.62, 0.62].forEach(z => sub(g, new T.BoxGeometry(0.02, 0.14, 0.2), { color: z < 0 ? 'green' : 'yellow', glow: true }, [s[0] / 2 + 0.004, 1.15, z]));
        } else if (type === 'jack') {
          box([1.2, 0.55, 0.6], { color: '#2b2e34' }, [0, 0.275, 0]);
          sub(g, new T.CylinderGeometry(0.3, 0.3, 0.3, 24).rotateZ(Math.PI / 2), { color: '#2b2e34' }, [0.72, 0.3, 0]);
          sub(g, new T.CircleGeometry(0.12, 20).rotateY(Math.PI / 2), { color: '#0d0e10' }, [0.871, 0.3, 0]);
        } else if (type === 'sd') {
          box([1.15, 0.15, 1.2], shell, [0, 0.075, 0]);
        } else if (type === 'ribbon') {
          box([0.5, 0.55, 2.2], { color: '#f2f0e8' }, [0, 0.275, 0]);
          sub(g, new T.BoxGeometry(0.12, 0.08, 1.9), { color: o.color || '#1d1f24' }, [0.1, 0.58, 0]);
        } else if (type === 'header') {
          const [cols, rows] = o.count || [20, 2], p = 0.254, list = [];
          box([cols * p, 0.25, rows * p], { color: '#1d1f24' }, [0, 0.125, 0], false);
          for (let i = 0; i < cols; i++) for (let j = 0; j < rows; j++) {
            const geo = new T.BoxGeometry(0.064, 0.85, 0.064); geo.translate((i - (cols - 1) / 2) * p, 0.425, (j - (rows - 1) / 2) * p); list.push(geo);
          }
          sub(g, mergeGeos(list), { color: 'gold', metal: true });
        }
        const f = o.face || 'x';
        if (f === '-x') g.rotation.y = Math.PI; else if (f === 'z') g.rotation.y = -Math.PI / 2; else if (f === '-z') g.rotation.y = Math.PI / 2;
        else if (f === 'y') g.rotation.z = Math.PI / 2;
        const outer = new T.Group(); outer.add(g);
        return finishPart(outer, o);
      },
      /** A camera lens / optic: a barrel with glass on top. axis: where it looks (default 'y', up). */
      lens(o = {}) {
        const r = o.r ?? 0.4, h = o.h ?? r * 1.1, g = new T.Group();
        sub(g, new T.CylinderGeometry(r, r * 1.08, h, 40), { color: o.color || '#25282d', rough: 0.4 }, [0, h / 2, 0]);
        sub(g, new T.TorusGeometry(r * 0.82, r * 0.1, 10, 40).rotateX(Math.PI / 2), { color: 'metal', metal: true }, [0, h, 0]);
        const glass = new T.MeshStandardMaterial({ color: '#4a6fa8', roughness: 0.05, metalness: 0.6, emissive: '#0c1a33' });
        sub(g, new T.SphereGeometry(r * 0.72, 32, 12, 0, 2 * Math.PI, 0, Math.PI / 2).scale(1, 0.35, 1), glass, [0, h, 0]);
        return finishPart(orientKids(g, o.axis || 'y'), o);
      },
      /** A wheel: tire, rim and spokes. axis default 'z' (the axle; a car driving along x). */
      wheel(o = {}) {
        const r = o.r ?? 0.5, wd = o.width ?? r * 0.6, g = new T.Group();
        const prof = [[0.62, -0.5], [0.8, -0.5], [0.95, -0.42], [1, -0.2], [1, 0.2], [0.95, 0.42], [0.8, 0.5], [0.62, 0.5]].map(([a, b]) => new T.Vector2(a * r, b * wd));
        sub(g, new T.LatheGeometry(prof, 48), { color: o.tire || '#2b2e34', rough: 0.9 });
        sub(g, new T.CylinderGeometry(r * 0.64, r * 0.64, wd * 0.7, 40, 1, true), { color: o.color || 'metal', metal: true });
        sub(g, new T.CylinderGeometry(r * 0.16, r * 0.16, wd * 0.8, 24), { color: o.color || 'metal', metal: true });
        const n = o.spokes ?? 5;
        for (let i = 0; i < n; i++) { const s = sub(g, new T.BoxGeometry(r * 0.13, wd * 0.25, r * 0.5).translate(0, wd * 0.15, r * 0.38), { color: o.color || 'metal', metal: true }); s.rotation.y = i * 2 * Math.PI / n; }
        return finishPart(orientKids(g, o.axis || 'z'), o);
      },
      /** A piston on a crank (slider-crank) that really works: the crank turns, the rod follows, the piston slides.
          r: crank radius (or stroke: the piston's travel, 2r), rod: rod length, bore: piston diameter. The crank turns
          around z (axis:'x' turns around x) and the piston rides up +y; tilt it with rot (a V engine: rot:[0,0,±45]).
          speed: radians per second (set .speed later to change it, 0 stops). phase: degrees (multi-cylinder engines);
          follow: another crank or linkage to turn with. Parts: .crank, .rod, .piston, .cylinder (a glass liner, liner:false
          leaves it out). .angle is the crank angle in radians (0 = piston at the top). */
      crank(o = {}) {
        const r = o.r ?? (o.stroke ? o.stroke / 2 : 0.5), L = Math.max(o.rod ?? r * 3.4, r * 1.3), bore = o.bore ?? r * 2.2;
        const th = Math.min(r * 0.4, bore * 0.3), ph = (o.phase ?? 0) * DEG;
        const g = new T.Group(), inner = new T.Group(); g.add(inner);
        if (o.axis === 'x') inner.rotation.y = Math.PI / 2;
        const zc = geo => geo.rotateX(Math.PI / 2);   // cylinders along z
        const steel = { color: o.crankColor || 'dark', metal: true };
        const crank = new T.Group(); crank.name = 'crank'; inner.add(crank);
        sub(crank, new T.BoxGeometry(r * 0.8, r, th), steel, [0, r / 2, -th * 1.15], { edges: true });
        sub(crank, zc(new T.CylinderGeometry(r * 0.4, r * 0.4, th, 32)), steel, [0, r, -th * 1.15]);
        sub(crank, zc(new T.CylinderGeometry(r, r, th, 40, 1, false, -Math.PI / 2, Math.PI)), steel, [0, 0, -th * 1.15], { edges: true });   // counterweight
        sub(crank, zc(new T.CylinderGeometry(r * 0.3, r * 0.3, th * 3, 24)), steel, [0, 0, -th * 1.6]);              // main journal
        sub(crank, zc(new T.CylinderGeometry(r * 0.24, r * 0.24, th * 1.6, 20)), { color: 'metal', metal: true }, [0, r, -th * 0.5]);   // crankpin
        const rod = new T.Group(); rod.name = 'rod'; inner.add(rod);
        const rodMat = { color: o.rodColor || 'metal', metal: true };
        sub(rod, new T.BoxGeometry(r * 0.3, L, th * 0.75).translate(0, L / 2, 0), rodMat, null, { edges: true });
        sub(rod, zc(new T.CylinderGeometry(r * 0.4, r * 0.4, th * 0.9, 28)), rodMat);
        sub(rod, zc(new T.CylinderGeometry(r * 0.24, r * 0.24, th * 0.9, 20)), rodMat, [0, L, 0]);
        const piston = new T.Group(); piston.name = 'piston'; inner.add(piston);
        sub(piston, new T.CylinderGeometry(bore / 2, bore / 2, bore * 0.8, 40), { color: o.color || 'light', metal: true }, [0, bore * 0.15, 0], { edges: true });
        for (const y of [0.45, 0.36]) sub(piston, new T.CylinderGeometry(bore * 0.503, bore * 0.503, bore * 0.035, 40), { color: 'dark' }, [0, bore * y, 0]);
        sub(piston, zc(new T.CylinderGeometry(r * 0.16, r * 0.16, bore * 0.92, 16)), { color: 'dark', metal: true });   // wrist pin
        let liner = null;
        if (o.liner !== false) {
          const y0 = L - r - bore * 0.25, y1 = L + r + bore * 0.63;
          liner = sub(inner, new T.CylinderGeometry(bore * 0.53, bore * 0.53, y1 - y0, 40, 1, true),
            { color: o.cylinderColor || '#bcd7ff', opacity: 0.16 }, [0, (y0 + y1) / 2, 0]);
          liner.material.depthWrite = false; liner.material.envMapIntensity = 0.35; liner.castShadow = false; liner.name = 'cylinder';
        }
        g.speed = o.speed ?? 4;
        g.angle = o.follow ? (o.follow.angle || 0) + ph : ph + g.speed * clock;   // same speed, same clock: cranks made one after another stay in step
        const pose = () => {
          const a = g.angle, px = r * Math.sin(a), py = r * Math.cos(a), yp = py + Math.sqrt(Math.max(0, L * L - px * px));
          crank.rotation.z = -a;
          rod.position.set(px, py, 0); rod.rotation.z = Math.atan2(px, yp - py);
          piston.position.y = yp;
        };
        pose();
        anims.push((t, dt) => { g.angle = o.follow ? (o.follow.angle || 0) + ph : g.angle + dt * g.speed; pose(); });
        Object.assign(g, { crank, rod, piston, cylinder: liner });
        return finishPart(g, o);
      },
      /** A planar linkage solved exactly every frame (a four-bar, a pump jack, a wiper, Theo Jansen's walking leg): a crank
          turns and every other joint sits where its two bars meet. Points are [x, y] in the plane seen face-on from kit.view('side') (axis:'x' turns
          it to face x). fixed: {name:[x,y]} pivots on the frame. crank: {name, around:'<fixed point>', r, speed, phase}
          (radians per second, degrees). joints: {name:{from:['P','Q'], len:[toP, toQ], side:'up'|'down'|'left'|'right'}}:
          the point len[0] from P and len[1] from Q; side picks which of the two possible spots it starts at. bars: [['P','Q'], …]
          links to draw; plates: [['P','Q','R'], …] rigid triangles. trace: a point name (or names) whose path is drawn.
          unit scales the numbers (unit:0.01 for cm). preset:'jansen' is a Strandbeest leg (size: about its height).
          .joint(name) is that pin (label it), .point(name) its position now, .angle / .speed / follow like kit.crank. */
      linkage(o = {}) {
        if (o.preset === 'jansen') o = { ...JANSEN(o.size ?? 4), ...o };
        const fixed = o.fixed || {}, cr = o.crank || {}, joints = o.joints || {};
        if (!cr.name || !(cr.around in fixed)) throw new Error("kit.linkage needs crank:{name, around:'<a fixed point>', r}");
        const known = new Set([...Object.keys(fixed), cr.name]), order = [], left = Object.keys(joints);
        while (left.length) {
          const i = left.findIndex(n => (joints[n].from || []).length === 2 && joints[n].from.every(p => known.has(p)));
          if (i < 0) throw new Error(`kit.linkage: joint ${left[0]} needs from:[two existing points] and len:[two lengths]`);
          known.add(left[i]); order.push(left.splice(i, 1)[0]);
        }
        const R = cr.r ?? 1, C0 = fixed[cr.around], ph = (cr.phase ?? o.phase ?? 0) * DEG, U = o.unit ?? 1;
        const d2 = (a, b) => (a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2;
        const pick = { up: (a, b) => a[1] >= b[1] ? a : b, down: (a, b) => a[1] <= b[1] ? a : b,
                       left: (a, b) => a[0] <= b[0] ? a : b, right: (a, b) => a[0] >= b[0] ? a : b };
        // Every point for crank angle ang. The first solve uses each joint's side; later ones stay on the branch the
        // linkage is already on (a real linkage can't jump to its mirror image). Returns the failing joint's name if a pair can't reach.
        const solve = (ang, prev) => {
          const Q = { ...fixed };
          Q[cr.name] = [C0[0] + R * Math.cos(ang), C0[1] + R * Math.sin(ang)];
          for (const n of order) {
            const j = joints[n], p0 = Q[j.from[0]], p1 = Q[j.from[1]], r0 = (j.len || [])[0], r1 = (j.len || [])[1];
            const dx = p1[0] - p0[0], dy = p1[1] - p0[1], D = Math.hypot(dx, dy), eps = 1e-6 * (r0 + r1);
            if (!(D > 1e-9) || D > r0 + r1 + eps || D < Math.abs(r0 - r1) - eps) return n;
            const a = (r0 * r0 - r1 * r1 + D * D) / (2 * D), h = Math.sqrt(Math.max(0, r0 * r0 - a * a));
            const mx = p0[0] + a * dx / D, my = p0[1] + a * dy / D;
            const s1 = [mx + h * dy / D, my - h * dx / D], s2 = [mx - h * dy / D, my + h * dx / D];
            Q[n] = prev ? (d2(s1, prev[n]) <= d2(s2, prev[n]) ? s1 : s2) : (pick[j.side] || pick.up)(s1, s2);
          }
          return Q;
        };
        const g = new T.Group(), inner = new T.Group(); g.add(inner);
        if (o.axis === 'x') inner.rotation.y = Math.PI / 2;
        g.speed = cr.speed ?? o.speed ?? 3;
        g.angle = o.follow ? (o.follow.angle || 0) + ph : ph + g.speed * clock;
        let Q = solve(g.angle, null);
        if (typeof Q === 'string') throw new Error(`kit.linkage: joint ${Q} can't reach both its points at the start (check its len)`);
        // Walk one full turn in 2° steps: the crank must be able to go all the way round. The samples draw the traces,
        // and each frame takes its branch from the nearest one, so the pose depends only on the angle, never on the frame rate.
        const N = 180, turn = [], a0 = g.angle, step = 2 * Math.PI / N;
        for (let i = 0, prev = Q; i < N; i++) {
          const s = solve(a0 + i * step, prev);
          if (typeof s === 'string') throw new Error(`kit.linkage: the crank can't make a full turn (joint ${s} can't reach at ${Math.round(i * 360 / N)}°); change the lengths`);
          turn.push(prev = s);
        }
        const names = new Set(known), check = l => l.forEach(n => { if (!names.has(n)) throw new Error(`kit.linkage: no point named ${n}`); });
        const bars = (o.bars || []).map(b => (check(b), b)), plates = (o.plates || []).map(p => (check(p), p));
        const lens = bars.map(([a, b]) => Math.sqrt(d2(Q[a], Q[b])) * U);
        const w = o.width ?? (lens.length ? lens.reduce((s, x) => s + x, 0) / lens.length : R * U * 3) * 0.12, th = w * 0.45;
        const layer = i => ((i % 3) - 1) * th * 1.25;
        const mat = { color: o.color || 'metal', metal: true };
        const barObjs = bars.map(([a, b], i) => {
          const len = lens[i], hw = w / 2, s = new T.Shape();
          s.moveTo(0, -hw); s.lineTo(len, -hw); s.absarc(len, 0, hw, -Math.PI / 2, Math.PI / 2, false);
          s.lineTo(0, hw); s.absarc(0, 0, hw, Math.PI / 2, Math.PI * 1.5, false);
          const geo = new T.ExtrudeGeometry(s, { depth: th, bevelEnabled: false, curveSegments: 10 }).translate(0, 0, -th / 2);
          const bg = new T.Group(); bg.name = a + b; bg.position.z = layer(i); inner.add(bg);
          sub(bg, geo, [a, b].sort().join() === [cr.name, cr.around].sort().join() ? { color: o.crankColor || 'dark', metal: true } : mat, null, { edges: true, edgeAngle: 40 });
          return { bg, a, b, len };
        });
        const plateObjs = plates.map(([a, b, c], i) => {
          const base = Math.atan2(Q[b][1] - Q[a][1], Q[b][0] - Q[a][0]), loc = p => {
            const x = (Q[p][0] - Q[a][0]) * U, y = (Q[p][1] - Q[a][1]) * U;
            return [x * Math.cos(-base) - y * Math.sin(-base), x * Math.sin(-base) + y * Math.cos(-base)];
          };
          const s = new T.Shape(); s.moveTo(0, 0); s.lineTo(...loc(b)); s.lineTo(...loc(c)); s.closePath();
          const pg = new T.Group(); pg.name = a + b + c; pg.position.z = layer(bars.length + i); inner.add(pg);
          sub(pg, new T.ExtrudeGeometry(s, { depth: th, bevelEnabled: false }).translate(0, 0, -th / 2), { color: o.plateColor || 'gray', metal: true }, null, { edges: true });
          return { pg, a, b };
        });
        const pins = {};
        for (const n of names) {
          const isFixed = n in fixed;
          if (!isFixed && ![...bars, ...plates].some(l => l.includes(n))) continue;
          const pg = new T.Group(); pg.name = n; inner.add(pg);
          sub(pg, new T.CylinderGeometry(w * (isFixed ? 0.5 : 0.3), w * (isFixed ? 0.5 : 0.3), th * (isFixed ? 5 : 4), 20).rotateX(Math.PI / 2),
            { color: isFixed ? 'black' : 'dark', metal: true });
          pins[n] = pg;
        }
        [].concat(o.trace || []).filter(n => names.has(n)).forEach(n => {
          const curve = new T.CatmullRomCurve3(turn.map(q => new T.Vector3(q[n][0] * U, q[n][1] * U, th * 2.2)), true);
          const m = new T.Mesh(new T.TubeGeometry(curve, N, w * 0.1, 8, true), new T.MeshBasicMaterial({ color: color(o.traceColor || 'orange') }));
          m.name = 'trace ' + n; inner.add(m);
        });
        const pose = () => {
          for (const n in pins) pins[n].position.set(Q[n][0] * U, Q[n][1] * U, 0);
          for (const { bg, a, b, len } of barObjs) {
            const dx = (Q[b][0] - Q[a][0]) * U, dy = (Q[b][1] - Q[a][1]) * U;
            bg.position.x = Q[a][0] * U; bg.position.y = Q[a][1] * U;
            bg.rotation.z = Math.atan2(dy, dx); bg.scale.x = Math.hypot(dx, dy) / (len || 1);
          }
          for (const { pg, a, b } of plateObjs) {
            pg.position.x = Q[a][0] * U; pg.position.y = Q[a][1] * U;
            pg.rotation.z = Math.atan2(Q[b][1] - Q[a][1], Q[b][0] - Q[a][0]);
          }
        };
        pose();
        anims.push((t, dt) => {
          g.angle = o.follow ? (o.follow.angle || 0) + ph : g.angle + dt * g.speed;
          const i = ((Math.round((g.angle - a0) / step) % N) + N) % N, s = solve(g.angle, turn[i]);
          if (typeof s !== 'string') { Q = s; pose(); }
        });
        g.joint = n => pins[n] || null;
        g.point = n => { if (!Q[n]) return null; inner.updateWorldMatrix(true, false); return inner.localToWorld(new T.Vector3(Q[n][0] * U, Q[n][1] * U, 0)); };
        g.points = () => Q;
        return finishPart(g, o);
      },
      /** A double helix (DNA): two backbones with base-pair rungs, along y from at. */
      helix(o = {}) {
        const r = o.r ?? 0.5, h = o.h ?? 3, turns = o.turns ?? h / (r * 3.4), g = new T.Group(), off = (o.offset ?? 150) * DEG;
        const strand = ph => { const pts = []; for (let i = 0; i <= turns * 32; i++) { const a = i / 32 * 2 * Math.PI + ph; pts.push(new T.Vector3(r * Math.cos(a), h * i / (turns * 32), r * Math.sin(a))); } return new T.CatmullRomCurve3(pts); };
        const c1 = strand(0), c2 = strand(off);
        sub(g, new T.TubeGeometry(c1, Math.ceil(turns * 64), r * 0.09, 10), { color: o.color || 'blue' });
        sub(g, new T.TubeGeometry(c2, Math.ceil(turns * 64), r * 0.09, 10), { color: o.color2 || o.color || 'purple' });
        const pairs = o.pairs || ['A-T', 'C-G'], cols = { A: 'red', T: 'yellow', C: 'green', G: 'orange', U: 'teal' };
        const n = Math.round(turns * (o.rungs ?? 10));
        for (let i = 0; i < n; i++) {
          const u = (i + 0.5) / n, a = c1.getPointAt(u), b = c2.getPointAt(u), mid = a.clone().lerp(b, 0.5);
          const pr = pairs[i % pairs.length].split('-'), flip = (i * 7) % 3 === 0;
          [[a, pr[flip ? 1 : 0]], [b, pr[flip ? 0 : 1]]].forEach(([p, base]) => {
            const len = p.distanceTo(mid), m = sub(g, new T.CylinderGeometry(r * 0.06, r * 0.06, len, 8), { color: cols[base] || 'gray' });
            m.position.copy(p).lerp(mid, 0.5); m.quaternion.setFromUnitVectors(AX.y, mid.clone().sub(p).normalize()); m.name = base;
          });
        }
        return finishPart(g, o);
      },
      /** A ball-and-stick molecule. Either a name ('water', 'co2', 'methane', 'ammonia', 'oxygen', 'nitrogen',
          'hydrogen', 'ethanol', 'benzene') or atoms: [['O', [x,y,z]], ['H', [...]], ...] in ångströms, with bonds
          [[i, j, order], ...] (found from distances if left out). scale: size of 1 Å in your units (default 1). */
      molecule(o = {}) {
        if (typeof o === 'string') o = { name: o };
        const pre = MOLECULES[String(o.name || '').toLowerCase()] || {};
        const atoms = (o.atoms || pre.atoms || []).map(a => Array.isArray(a) ? { el: a[0], at: a[1] } : a);
        const k = o.scale ?? 1, g = new T.Group(), list = [];
        atoms.forEach((a, i) => {
          const [r, c] = ELEMENTS[a.el] || [0.45, '#d6409f'];
          const m = sub(g, new T.SphereGeometry(r * k * (o.ball ?? 1), 32, 20), { color: a.color || c, rough: 0.35 }, (a.at || [0, 0, 0]).map(x => x * k));
          m.name = a.el + (i + 1); list.push(m);
        });
        let bonds = o.bonds || pre.bonds;
        if (!bonds) {
          bonds = [];
          for (let i = 0; i < list.length; i++) for (let j = i + 1; j < list.length; j++) {
            const ri = (ELEMENTS[atoms[i].el] || [0.45])[0], rj = (ELEMENTS[atoms[j].el] || [0.45])[0];
            if (list[i].position.distanceTo(list[j].position) / k < (ri + rj) * 1.85) bonds.push([i, j, 1]);
          }
        }
        const bm = material({ color: o.bondColor || '#c9ccd2', rough: 0.4 });
        for (const [i, j, ord = 1] of bonds) {
          const a = list[i] && list[i].position, b = list[j] && list[j].position; if (!a || !b) continue;
          const dir = b.clone().sub(a), len = dir.length(), side = new T.Vector3().crossVectors(dir, Math.abs(dir.y) < 0.9 * len ? AX.y : AX.x).normalize();
          for (let q = 0; q < ord; q++) {
            const m = sub(g, new T.CylinderGeometry(0.08 * k, 0.08 * k, len, 12), bm);
            m.position.copy(a).lerp(b, 0.5).addScaledVector(side, (q - (ord - 1) / 2) * 0.2 * k);
            m.quaternion.setFromUnitVectors(AX.y, dir.clone().normalize());
          }
        }
        return finishPart(g, o);
      },
      /** A planet, moon or star with a generated surface: kind 'earth', 'moon', 'mars', 'sun', 'jupiter', 'saturn'
          (with rings), 'venus', 'ice', or colors: [low, high]. tilt: axial tilt in degrees (spin it with kit.spin(p, 'y')). */
      planet(o = {}) {
        const kind = o.kind || 'earth', r = o.r ?? 1, nz = noise3(o.seed ?? (kind.length * 13));
        floor = false; if (shadow) { scene.remove(shadow); shadow = null; }   // planets float in space: no floor shadow
        const W = 384, H = 192, cv = document.createElement('canvas'); cv.width = W; cv.height = H;
        const g2 = cv.getContext('2d'), img = g2.createImageData(W, H), c = new T.Color(), tmp = new T.Color();
        const pal = { earth: ['#1f4f9e', '#3f8f4f'], moon: ['#8d9096', '#c9cbcf'], mars: ['#a8482a', '#d98a52'], sun: ['#ff8a00', '#ffe27a'],
                      jupiter: ['#b98a5e', '#efe2c8'], saturn: ['#c9a96e', '#f0e2b8'], venus: ['#d9b06a', '#f2dcaa'], ice: ['#7fb2d9', '#e8f4ff'] };
        const [lo, hi] = (o.colors || pal[kind] || pal.moon).map(x => color(x));
        for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
          const lon = x / W * 2 * Math.PI, lat = (0.5 - y / H) * Math.PI, px = Math.cos(lat) * Math.cos(lon), py = Math.sin(lat), pz = Math.cos(lat) * Math.sin(lon);
          const n = nz(px * 2.2 + 5, py * 2.2 + 5, pz * 2.2 + 5);
          if (kind === 'earth') {
            if (n > 0.56) { c.set('#4f9a4a').lerp(tmp.set('#c2a46a'), Math.min(1, (n - 0.56) * 5)); }
            else c.copy(lo).lerp(tmp.set('#2f6fc0'), Math.max(0, (n - 0.38) * 6));
            if (Math.abs(lat) > 1.2 + (n - 0.5) * 0.4) c.set('#f4f7fb');
          } else if (kind === 'jupiter' || kind === 'saturn') {
            const b = 0.5 + 0.5 * Math.sin(lat * 14 + n * 3);
            c.copy(lo).lerp(hi, b);
            if (kind === 'jupiter') { const dx = Math.atan2(Math.sin(lon - 4.2), Math.cos(lon - 4.2)), dy = lat + 0.38; if (dx * dx / 0.05 + dy * dy / 0.012 < 1) c.set('#c8573a'); }
          } else if (kind === 'moon') {
            const cr = nz(px * 9, py * 9, pz * 9, 3); c.copy(lo).lerp(hi, Math.min(1, Math.max(0, n * 1.4 - 0.2 - (cr > 0.62 ? 0.3 : 0))));
          } else if (kind === 'mars') {
            c.copy(lo).lerp(hi, n); if (Math.abs(lat) > 1.35) c.set('#f1ece6');
          } else c.copy(lo).lerp(hi, n);
          const i = 4 * (x + y * W); c.convertLinearToSRGB();
          img.data[i] = c.r * 255; img.data[i + 1] = c.g * 255; img.data[i + 2] = c.b * 255; img.data[i + 3] = 255;
        }
        g2.putImageData(img, 0, 0);
        const tex = new T.CanvasTexture(cv); tex.colorSpace = T.SRGBColorSpace;
        const isSun = kind === 'sun' || o.glow;
        const mat = new T.MeshStandardMaterial({ map: tex, roughness: kind === 'earth' ? 0.75 : 0.9, metalness: 0,
          emissive: isSun ? new T.Color('#ffffff') : new T.Color(0), emissiveMap: isSun ? tex : null, emissiveIntensity: isSun ? 1.1 : 0 });
        const m = new T.Mesh(new T.SphereGeometry(r, 64, 40), mat);
        m.castShadow = !isSun; m.receiveShadow = !isSun;
        if (kind === 'earth' && o.clouds !== false) {
          const cc = document.createElement('canvas'); cc.width = 256; cc.height = 128;
          const cg = cc.getContext('2d'), ci = cg.createImageData(256, 128), cn = noise3(91);
          for (let y = 0; y < 128; y++) for (let x = 0; x < 256; x++) {
            const lon = x / 256 * 2 * Math.PI, lat = (0.5 - y / 128) * Math.PI;
            const v = cn(Math.cos(lat) * Math.cos(lon) * 3 + 9, Math.sin(lat) * 3 + 9, Math.cos(lat) * Math.sin(lon) * 3 + 9), i = 4 * (x + y * 256);
            ci.data[i] = ci.data[i + 1] = ci.data[i + 2] = 255; ci.data[i + 3] = Math.max(0, Math.min(255, (v - 0.55) * 900));
          }
          cg.putImageData(ci, 0, 0);
          const ct = new T.CanvasTexture(cc); ct.colorSpace = T.SRGBColorSpace;
          const cl = new T.Mesh(new T.SphereGeometry(r * 1.015, 48, 32), new T.MeshStandardMaterial({ map: ct, transparent: true, depthWrite: false, roughness: 1 }));
          cl.userData.helper = true; cl.raycast = () => {}; m.add(cl);
        }
        if (isSun) { const halo = new T.Mesh(new T.SphereGeometry(r * 1.25, 32, 20), new T.MeshBasicMaterial({ color: '#ffb340', transparent: true, opacity: 0.18, side: T.BackSide, depthWrite: false })); halo.userData.helper = true; halo.raycast = () => {}; m.add(halo); }
        if (o.rings || kind === 'saturn') {
          const ring = new T.Mesh(new T.RingGeometry(r * 1.3, r * 2.2, 96, 1).rotateX(-Math.PI / 2),
            new T.MeshStandardMaterial({ color: '#d8c9a3', transparent: true, opacity: 0.75, side: T.DoubleSide, roughness: 1 }));
          m.add(ring);
        }
        const p = place(m, { ...o, edges: false });
        if (o.tilt) { p.rotation.order = 'ZYX'; p.rotation.z = -o.tilt * DEG; }   // spin on 'y' then turns around the tilted axis
        return p;
      },
      /** Water with moving waves (a sea, a lake, a pool). size [x, z]; the surface sits at at. */
      water(o = {}) {
        const [w, d] = o.size || [20, 14], n = 70, geo = new T.PlaneGeometry(w, d, n, n).rotateX(-Math.PI / 2);
        const m = new T.Mesh(geo, new T.MeshStandardMaterial({ color: color(o.color || '#3a86c8'), roughness: 0.2, metalness: 0.1, transparent: true, opacity: o.opacity ?? 0.88, side: T.DoubleSide }));
        const pos = geo.attributes.position, amp = o.waves ?? Math.min(w, d) * 0.008, base = Float32Array.from(pos.array);
        let frameN = 0;
        anims.push(t => {
          if (frameN++ % 2) return;
          for (let i = 0; i < pos.count; i++) { const x = base[3 * i], z = base[3 * i + 2]; pos.setY(i, amp * (Math.sin(x * 0.9 + t * 1.6) + 0.6 * Math.sin(z * 1.3 - t * 1.2 + x * 0.4))); }
          pos.needsUpdate = true; geo.computeVertexNormals();
        });
        m.receiveShadow = true; m.userData.isWater = true;
        return place(m, { ...o, edges: false });
      },
      /** A tree for scenes. kind: 'round' (default), 'pine', 'palm'. h: height. */
      tree(o = {}) {
        const h = o.h ?? 2, kind = o.kind || 'round', g = new T.Group(), trunk = { color: '#8a5a36', rough: 0.9 };
        const leaf = { color: o.color || (kind === 'pine' ? '#2f7a4a' : '#4f9a4a'), rough: 0.85, flat: true };
        if (kind === 'pine') {
          sub(g, new T.CylinderGeometry(h * 0.04, h * 0.05, h * 0.3, 8), trunk, [0, h * 0.15, 0]);
          for (let i = 0; i < 3; i++) sub(g, new T.ConeGeometry(h * (0.3 - i * 0.07), h * 0.42, 9), leaf, [0, h * (0.38 + i * 0.2), 0]);
        } else if (kind === 'palm') {
          const pts = [0, 0.3, 0.6, 0.9].map(u => new T.Vector3(u * u * h * 0.15, u * h * 0.9, 0));
          sub(g, new T.TubeGeometry(new T.CatmullRomCurve3(pts), 16, h * 0.035, 8), trunk);
          for (let i = 0; i < 7; i++) { const l = sub(g, new T.SphereGeometry(h * 0.28, 10, 6).scale(1, 0.12, 0.3).translate(h * 0.24, -h * 0.03, 0), leaf, [h * 0.12, h * 0.82, 0]); l.rotation.y = i * 2 * Math.PI / 7; l.rotation.z = -0.35; }
        } else {
          sub(g, new T.CylinderGeometry(h * 0.045, h * 0.06, h * 0.5, 8), trunk, [0, h * 0.25, 0]);
          [[0, 0.62, 0, 0.3], [0.13, 0.52, 0.06, 0.2], [-0.12, 0.55, -0.05, 0.21], [0.02, 0.8, 0.03, 0.2]].forEach(([x, y, z, r]) =>
            sub(g, new T.IcosahedronGeometry(h * r, 1), leaf, [h * x, h * y, h * z]));
        }
        return finishPart(g, o);
      },
      /** A building: size [x, y, z], windows on the walls. roof: 'flat' (default) or 'gable' (a house). */
      building(o = {}) {
        const [w, hh, d] = o.size || [2, 4, 2], g = new T.Group(), wall = color(o.color || '#e8e4dc');
        const floor = o.floorHeight ?? Math.max(0.3, Math.min(hh / 2, 0.35 * Math.max(1, hh / 3)));
        const mk = (len) => {
          const cv = document.createElement('canvas'), cols = Math.max(1, Math.round(len / (floor * 0.9))), rows = Math.max(1, Math.round(hh / floor));
          cv.width = cols * 24; cv.height = rows * 24;
          const x = cv.getContext('2d'); x.fillStyle = '#' + wall.getHexString(); x.fillRect(0, 0, cv.width, cv.height);
          x.fillStyle = o.windowColor || '#5b7fa8';
          for (let i = 0; i < cols; i++) for (let j = 0; j < rows; j++) x.fillRect(i * 24 + 6, j * 24 + 6, 12, 12);
          const t = new T.CanvasTexture(cv); t.colorSpace = T.SRGBColorSpace; return new T.MeshStandardMaterial({ map: t, roughness: 0.8 });
        };
        const plain = new T.MeshStandardMaterial({ color: wall.clone().multiplyScalar(0.92), roughness: 0.85 });
        const sx = mk(d), sz = mk(w);
        const m = new T.Mesh(new T.BoxGeometry(w, hh, d), [sx, sx, plain, plain, sz, sz]);
        m.position.y = hh / 2; m.castShadow = m.receiveShadow = true; g.add(m);
        if (o.roof === 'gable') {
          const rh = Math.min(w, d) * 0.45, sh = new T.Shape([new T.Vector2(-w / 2 - 0.08, 0), new T.Vector2(w / 2 + 0.08, 0), new T.Vector2(0, rh)]);
          const rg = new T.ExtrudeGeometry(sh, { depth: d + 0.16, bevelEnabled: false }); rg.translate(0, 0, -(d + 0.16) / 2);
          sub(g, rg, { color: o.roofColor || '#b5523b' }, [0, hh, 0], { edges: true });
        }
        return finishPart(g, o);
      },
      /** A car (kind 'car', 'truck', 'bus') facing +x, wheels included. length: along x. */
      car(o = {}) {
        const L = o.length ?? 4.2, kind = o.kind || 'car', g = new T.Group(), c = { color: o.color || 'red', rough: 0.35, metal: true };
        const W = L * (kind === 'car' ? 0.43 : 0.38), H = L * (kind === 'car' ? 0.16 : kind === 'bus' ? 0.27 : 0.2), r = L * (kind === 'car' ? 0.085 : 0.075);
        sub(g, roundedBox(L, H, W, H * 0.3), c, [0, r + H * 0.45, 0], { edges: true, edgeAngle: 50 });
        const glass = new T.MeshStandardMaterial({ color: '#36475e', roughness: 0.1, metalness: 0.5 });
        if (kind === 'car') { sub(g, roundedBox(L * 0.5, H * 0.75, W * 0.88, H * 0.3), c, [-L * 0.05, r + H * 1.2, 0], { edges: true, edgeAngle: 50 }); sub(g, roundedBox(L * 0.46, H * 0.55, W * 0.9, H * 0.2), glass, [-L * 0.05, r + H * 1.22, 0]); }
        else if (kind === 'truck') { sub(g, roundedBox(L * 0.28, H * 1.1, W, H * 0.25), c, [L * 0.34, r + H * 1.3, 0], { edges: true, edgeAngle: 50 }); sub(g, new T.BoxGeometry(0.02, H * 0.5, W * 0.85), glass, [L * 0.48, r + H * 1.45, 0]); }
        else sub(g, new T.BoxGeometry(L * 0.9, H * 0.25, W * 1.01), glass, [0, r + H * 0.7, 0]);
        for (const x of kind === 'car' ? [0.32, -0.32] : [0.34, -0.2, -0.36]) for (const z of [1, -1]) kit.wheel({ r, width: r * 0.7, parent: g, at: [x * L, r, z * W * 0.46], color: 'metal', spokes: 5 });
        return finishPart(g, o);
      },
      /** A rocket or missile facing +x (the way it flies). length; fins: number of tail fins. */
      rocket(o = {}) {
        const L = o.length ?? 2, R = o.r ?? L * 0.05, g = new T.Group(), c = { color: o.color || 'white', rough: 0.4 };
        const prof = [[0, 0.5], [0.45, 0.42], [0.85, 0.3], [1, 0.12], [1, -0.42], [0.9, -0.5]].map(([rr, x]) => new T.Vector2(Math.max(0.001, rr * R), x * L));
        prof.reverse(); sub(g, new T.LatheGeometry(prof, 32), c);
        sub(g, new T.LatheGeometry([[0.88, 0.29], [0.85, 0.3], [0.45, 0.42], [0, 0.5]].map(([rr, x]) => new T.Vector2(Math.max(0.001, rr * R * 1.015), x * L + 0.001)).reverse(), 32), { color: o.noseColor || 'red' });
        const nf = o.fins ?? 4, fs = new T.Shape([new T.Vector2(0, 0), new T.Vector2(R * 2.2, -R * 1.2), new T.Vector2(R * 2.2, -R * 4.2), new T.Vector2(0, -R * 5)]);
        const fg = new T.ExtrudeGeometry(fs, { depth: R * 0.12, bevelEnabled: false }).translate(R * 0.9, -L * 0.5 + R * 5, -R * 0.06);
        for (let i = 0; i < nf; i++) { const f = sub(g, fg, { color: o.finColor || 'dark' }); f.rotation.y = i * 2 * Math.PI / nf; }
        sub(g, new T.CylinderGeometry(R * 0.7, R * 0.9, R * 1.2, 24), { color: 'dark', metal: true }, [0, -L * 0.5 - R * 0.4, 0]);
        if (o.flame) sub(g, new T.ConeGeometry(R * 0.8, R * 7, 20).rotateX(Math.PI), { color: 'orange', glow: 'orange', opacity: 0.85 }, [0, -L * 0.5 - R * 4.6, 0]).castShadow = false;
        return finishPart(orientKids(g, 'x'), o);
      },
      /** A simple airplane facing +x. length: nose to tail. kind 'jet' (default) or 'prop'. */
      airplane(o = {}) {
        const L = o.length ?? 4, R = L * 0.055, g = new T.Group(), c = { color: o.color || 'white', rough: 0.45 };
        const prof = [[0, -0.5], [0.6, -0.44], [0.95, -0.3], [1, 0.1], [0.85, 0.36], [0.45, 0.47], [0, 0.5]].map(([rr, x]) => new T.Vector2(Math.max(0.001, rr * R), x * L));
        const body = sub(g, new T.LatheGeometry(prof, 32), c); body.rotation.z = -Math.PI / 2;
        const wing = (span, root, tip, sweep, y, x, th) => {
          const s = new T.Shape([new T.Vector2(0, -root / 2), new T.Vector2(0, root / 2), new T.Vector2(span, root / 2 - sweep), new T.Vector2(span, root / 2 - sweep - tip)]);
          const geo = new T.ExtrudeGeometry(s, { depth: th, bevelEnabled: false }).translate(0, 0, -th / 2).rotateX(Math.PI / 2).rotateY(Math.PI / 2);
          sub(g, geo, c, [x, y, 0], { edges: true });                         // span → -z, chord → +x
          sub(g, geo.clone().scale(1, 1, -1), c, [x, y, 0], { edges: true }); // the mirror wing
        };
        wing(L * 0.48, L * 0.22, L * 0.07, L * 0.14, -R * 0.2, L * 0.02, R * 0.25);
        wing(L * 0.17, L * 0.1, L * 0.04, L * 0.06, R * 0.3, -L * 0.42, R * 0.18);
        const fin = new T.Shape([new T.Vector2(0, 0), new T.Vector2(L * 0.14, 0), new T.Vector2(L * 0.04, L * 0.16), new T.Vector2(-L * 0.03, L * 0.16)]);
        sub(g, new T.ExtrudeGeometry(fin, { depth: R * 0.18, bevelEnabled: false }).translate(-L * 0.5, R * 0.4, -R * 0.09), { color: o.tailColor || o.color || 'white' }, null, { edges: true });
        sub(g, new T.SphereGeometry(R * 0.6, 16, 10).scale(2.2, 0.8, 1), new T.MeshStandardMaterial({ color: '#36475e', roughness: 0.1, metalness: 0.5 }), [L * 0.38, R * 0.55, 0]);
        if ((o.kind || 'jet') === 'jet') [1, -1].forEach(sg => sub(g, new T.CylinderGeometry(R * 0.45, R * 0.4, L * 0.16, 20).rotateZ(Math.PI / 2), { color: 'metal', metal: true }, [L * 0.05, -R * 0.9, sg * L * 0.17]));
        else sub(g, new T.BoxGeometry(R * 0.2, R * 3.4, R * 0.4), { color: 'dark' }, [L * 0.52, 0, 0]);
        return finishPart(g, o);
      },
      /** A soft cloud. size: its width. */
      cloud(o = {}) {
        const s = o.size ?? 2, g = new T.Group(), m = { color: o.color || 'white', rough: 1, opacity: o.opacity ?? 0.95 };
        [[0, 0, 0, 0.32], [0.28, -0.04, 0.05, 0.24], [-0.3, -0.06, -0.03, 0.22], [0.1, 0.16, -0.05, 0.22], [-0.12, 0.1, 0.12, 0.2]].forEach(([x, y, z, r]) =>
          sub(g, new T.SphereGeometry(s * r, 18, 12), m, [s * x, s * y, s * z]).castShadow = false);
        return finishPart(g, o);
      },
      /** A rock or boulder (irregular). size: its width. */
      rock(o = {}) {
        const s = o.size ?? 1, geo = new T.IcosahedronGeometry(s / 2, 2), p = geo.attributes.position, nz = noise3(o.seed ?? 5);
        for (let i = 0; i < p.count; i++) { const v = new T.Vector3().fromBufferAttribute(p, i), k = 0.75 + 0.5 * nz(v.x * 3 / s + 3, v.y * 3 / s + 3, v.z * 3 / s + 3, 3); v.multiplyScalar(k); v.y *= 0.7; p.setXYZ(i, v.x, v.y, v.z); }
        geo.computeVertexNormals();
        return mesh(geo, { ...o, color: o.color || '#9a958c', flat: true, edges: false, at: o.at });
      },
      /** A smooth organic shape blended from spheres and capsules (hearts, organs, cells, animals, plants, clay).
          parts: [{at, r, stretch?: [x,y,z]}, {from, to, r: number | [r1, r2]}, {..., cut: true} carves a hollow].
          smooth: how much they melt together (default half their size). Each part can have its own color. */
      blob(o = {}) {
        if (Array.isArray(o)) o = { parts: o };
        const m = blobMesh(o);
        if (!m) return null;
        return place(m, { ...o, edges: false });
      },
    });
    /** Pictures of the whole model (as if every part had finished arriving) from a few angles, as JPEG data
        URLs, for a second look at what was built. views: [{az, el}] in degrees; default the current angle and
        one from the other side, higher up. Rendered off to the side: the camera on screen doesn't move. */
    kit.snapshot = function (o = {}) {
      const box = contentBox();
      if (box.isEmpty()) return [];
      const center = box.getCenter(new T.Vector3()), size = o.size || 768;
      const views = o.views || [{ az: cam.baseAz / DEG, el: cam.el / DEG }, { az: cam.baseAz / DEG + 110, el: 38 }];
      const saved = { p: camera.position.clone(), q: camera.quaternion.clone(), near: camera.near, far: camera.far };
      const out = [], cv = document.createElement('canvas'), w = renderer.domElement.width, h = renderer.domElement.height;
      const k = Math.min(1, size / Math.max(w, h)); cv.width = Math.round(w * k); cv.height = Math.round(h * k);
      const g = cv.getContext('2d');
      measure(() => {
        world.updateMatrixWorld(true);
        for (const v of views) {
          const az = v.az * DEG, el = v.el * DEG, d = fitDistance(box, center, az, el) * 1.06;
          camera.position.set(Math.cos(el) * Math.sin(az), Math.sin(el), Math.cos(el) * Math.cos(az)).multiplyScalar(d).add(center);
          camera.near = d / 100; camera.far = d * 100; camera.updateProjectionMatrix(); camera.lookAt(center);
          renderer.render(scene, camera);
          g.fillStyle = o.background || '#eef1f5'; g.fillRect(0, 0, cv.width, cv.height);
          g.drawImage(renderer.domElement, 0, 0, cv.width, cv.height);
          out.push(cv.toDataURL('image/jpeg', 0.8));
        }
      });
      camera.position.copy(saved.p); camera.quaternion.copy(saved.q); camera.near = saved.near; camera.far = saved.far; camera.updateProjectionMatrix();
      renderer.render(scene, camera);
      return out;
    };
    // A better person: limbs are named groups (armL, armR, legL, legR) you can rotate. walk: true swings them.
    kit.person = function (o = {}) {
      const h = o.height ?? 1.75, g = new T.Group(), m = material({ color: o.color || 'gray', rough: 0.7 });
      const skin = material({ color: o.skin || '#e8b99a', rough: 0.7 });
      const torso = sub(g, new T.CapsuleGeometry(h * 0.085, h * 0.2, 6, 16), m, [0, h * 0.635, 0]); torso.scale.set(1.25, 1, 0.75);
      sub(g, new T.SphereGeometry(h * 0.068, 24, 16), skin, [0, h * 0.905, 0]);
      sub(g, new T.CylinderGeometry(h * 0.025, h * 0.03, h * 0.05, 10), skin, [0, h * 0.82, 0]);
      const limb = (name, at, r, len, mat) => {
        const pv = new T.Group(); pv.name = name; pv.position.set(...at); g.add(pv);
        sub(pv, new T.CapsuleGeometry(r, len, 4, 10), mat, [0, -len / 2 - r * 0.4, 0]);
        return pv;
      };
      const legs = [limb('legL', [h * 0.055, h * 0.48, 0], h * 0.045, h * 0.38, m), limb('legR', [-h * 0.055, h * 0.48, 0], h * 0.045, h * 0.38, m)];
      const arms = [limb('armL', [h * 0.13, h * 0.775, 0], h * 0.032, h * 0.3, m), limb('armR', [-h * 0.13, h * 0.775, 0], h * 0.032, h * 0.3, m)];
      arms[0].rotation.z = 0.08; arms[1].rotation.z = -0.08;
      if (o.walk) anims.push(t => { const s = Math.sin(t * 6) * 0.5; legs[0].rotation.x = s; legs[1].rotation.x = -s; arms[0].rotation.x = -s * 0.8; arms[1].rotation.x = s * 0.8; });
      return finishPart(g, o);
    };

    // ---------- the model's code: one shared scope, statement by statement ----------
    const vars = { kit, THREE: T };
    const scope = new Proxy(vars, { has: (t, k) => typeof k === 'string' && k in t });
    // Typing slips models make that aren't JavaScript: "−2" (a Unicode minus), 'Earth's orbit'.
    function repair(code) {
      return code.replace(/[\u2212\u2013]/g, '-').replace(/[\u201C\u201D]/g, '"')
        .replace(/(\w)'(s|t|re|ll|ve|d|m)\b/g, '$1\u2019$2');
    }
    function compile(code) {
      try { return new Function('__sb', 'with (__sb) {\n' + code + '\n}'); }
      catch (e) { if (!(e instanceof SyntaxError)) throw e; return new Function('__sb', 'with (__sb) {\n' + repair(code) + '\n}'); }
    }
    function runStatement(stmt) {
      const h = hoist(stmt);
      for (const n of h.names) if (!(n in vars)) vars[n] = undefined;
      compile(h.code)(scope);
    }
    function runAll(stmts) {
      const had = new Set(); world.traverse(o => had.add(o));
      const before = contentBox(), errors = [], focusBefore = focusCount;
      for (const st of stmts) {
        try { runStatement(st); }
        catch (e) { errors.push(`${(e && e.message) || e} (in: ${st.length > 160 ? st.slice(0, 160) + '…' : st})`); }
      }
      if (!before.equals(contentBox()) && focusCount === focusBefore) fit();   // new parts: smoothly re-frame (unless the step zoomed to one)
      // New parts drop in (the topmost new object of each new branch).
      const fresh = [];
      world.traverse(o => { if (!had.has(o) && had.has(o.parent) && !o.userData.isGround && !o.userData.noIntro && !o.userData.helper && !o.isLineSegments) fresh.push(o); });
      buildIn(fresh, 0);
      return errors;
    }

    // ---------- camera, framing, ground shadow ----------
    // What the camera frames: everything except floors (they're just there for shadows).
    function contentBox() {
      return measure(() => {
        const b = new T.Box3();
        world.children.forEach(c => {
          if (c.userData.isGround || !c.visible) return;
          const cb = new T.Box3().setFromObject(c), k = c.userData.cut;
          if (k && !cb.isEmpty()) {   // only what's left after a cut counts
            if (k.sgn > 0) cb.max[k.axis] = Math.max(cb.min[k.axis], Math.min(cb.max[k.axis], k.at));
            else cb.min[k.axis] = Math.min(cb.max[k.axis], Math.max(cb.min[k.axis], k.at));
          }
          b.union(cb);
        });
        return b;
      });
    }
    function fit() {
      const box = contentBox();
      if (box.isEmpty()) return;
      const size = box.getSize(new T.Vector3()), center = box.getCenter(new T.Vector3());
      const radius = size.length() / 2 || 1;
      focused = false;
      cam.goalTarget.copy(center);
      // While it's being built, look at its long side (unless the code chose a view): things built
      // along z would otherwise be seen end-on.
      if (building && !viewChosen && !camTween && (performance.now() - t0) / 1000 - lastInteract > 5) {
        cam.baseAz = (size.z > size.x * 1.3 ? 62 : 32) * DEG;
      }
      // Frame the model's outline as seen from where the camera is heading (room for the tags if any).
      const az = camTween ? camTween.az1 : cam.baseAz, el = camTween ? camTween.el1 : cam.el;
      const d = Math.max(fitDistance(box, center, az, el) * (labels.length ? 1.14 : 1.04), radius * 0.5);
      // While parts are still arriving, the camera only pulls back (no zooming in and out on each part).
      cam.goalDist = building && fitted ? Math.max(d, cam.goalDist) : d;
      if (!fitted) { cam.target.copy(center); cam.dist = cam.goalDist * 1.6; cam.az = cam.baseAz - 0.5; fitted = true; }   // swoop in
      // Shadows: aim the sun at the model and fit its shadow camera around it.
      sun.target.position.copy(center);
      sun.position.copy(center).add(new T.Vector3(0.45, 0.85, 0.6).normalize().multiplyScalar(radius * 3));
      const sc = sun.shadow.camera; sc.left = sc.bottom = -radius * 1.4; sc.right = sc.top = radius * 1.4;
      sc.near = radius * 0.5; sc.far = radius * 6; sc.updateProjectionMatrix();
      camera.near = cam.goalDist / 100; camera.far = cam.goalDist * 100; camera.updateProjectionMatrix();
      if (shadow) { scene.remove(shadow); shadow = null; }
      if (!floor) return;
      // soft contact shadow
      const cv = document.createElement('canvas'); cv.width = cv.height = 128;
      const g = cv.getContext('2d'), grd = g.createRadialGradient(64, 64, 0, 64, 64, 64);
      grd.addColorStop(0, 'rgba(0,0,0,0.28)'); grd.addColorStop(1, 'rgba(0,0,0,0)');
      g.fillStyle = grd; g.fillRect(0, 0, 128, 128);
      shadow = new T.Group();
      const blob = new T.Mesh(new T.PlaneGeometry(size.x * 1.3 || 1, size.z * 1.3 || 1),
        new T.MeshBasicMaterial({ map: new T.CanvasTexture(cv), transparent: true, depthWrite: false, opacity: 0.6 }));
      blob.rotation.x = -Math.PI / 2;
      const catcher = new T.Mesh(new T.PlaneGeometry(radius * 6, radius * 6), new T.ShadowMaterial({ opacity: 0.22 }));
      catcher.rotation.x = -Math.PI / 2; catcher.receiveShadow = true; catcher.position.y = 0.001;
      shadow.add(blob, catcher);
      shadow.position.set(center.x, box.min.y - size.y * 0.01, center.z);
      scene.add(shadow);
    }
    // A camera angle (near az/el) from which nothing else hides `obj`, or null if the current one is fine.
    function clearAngle(obj, pc, target, dist, az, el) {
      const blockers = [];
      world.traverse(m => { if (m.isMesh && m.visible && !m.userData.helper && !m.userData.isGround && !isInside(m, obj) && !isInside(obj, m)) blockers.push(m); });
      if (!blockers.length) return null;
      const r = new T.Raycaster();
      const hidden = (a, e) => {
        const cp = new T.Vector3(Math.cos(e) * Math.sin(a), Math.sin(e), Math.cos(e) * Math.cos(a)).multiplyScalar(dist).add(target);
        const dir = pc.clone().sub(cp), len = dir.length();
        r.set(cp, dir.normalize()); r.far = len * 0.97;
        return r.intersectObjects(blockers, false).some(h => !h.object.material || h.object.material.opacity > 0.5);
      };
      if (!hidden(az, el)) return null;
      for (const d of [30, -30, 60, -60, 90, -90, 135, -135, 180]) {
        for (const de of [0, 20, -15]) {
          const a = az + d * DEG, e = Math.max(-60 * DEG, Math.min(75 * DEG, el + de * DEG));
          if (!hidden(a, e)) return [a, e];
        }
      }
      return null;
    }
    function fitDistance(box, center, az, el, root) {
      const z = new T.Vector3(Math.cos(el) * Math.sin(az), Math.sin(el), Math.cos(el) * Math.cos(az));
      const x = new T.Vector3(0, 1, 0).cross(z).normalize(), y = z.clone().cross(x);
      const tanV = Math.tan(camera.fov * DEG / 2), tanH = tanV * W() / H();
      // The model's real outline (a sample of its vertices), so round things aren't framed by their box corners.
      let pts = outlinePoints(root);
      if (!pts.length) pts = [0, 1, 2, 3, 4, 5, 6, 7].map(i => new T.Vector3(i & 1 ? box.max.x : box.min.x, i & 2 ? box.max.y : box.min.y, i & 4 ? box.max.z : box.min.z));
      let d = 0;
      const c = new T.Vector3();
      for (const p of pts) {
        c.copy(p).sub(center);
        d = Math.max(d, c.dot(z) + Math.abs(c.dot(x)) / tanH, c.dot(z) + Math.abs(c.dot(y)) / tanV);
      }
      return d;
    }
    function outlinePoints(root) {
      root = root || world;
      return measure(() => {
        world.updateMatrixWorld(true);
        const pts = [];
        root.traverse(m => {
          if (!m.isMesh || m.userData.helper || m.userData.isGround || !m.geometry || !m.geometry.attributes.position) return;
          for (let p = m; p; p = p.parent) if (!p.visible) return;
          let cut = null; for (let p = m; p && !cut; p = p.parent) cut = p.userData.cut || null;
          const pos = m.geometry.attributes.position, stride = Math.max(1, Math.floor(pos.count / 300));
          for (let i = 0; i < pos.count; i += stride) {
            const v = new T.Vector3().fromBufferAttribute(pos, i).applyMatrix4(m.matrixWorld);
            if (cut && cut.sgn * (cut.at - v[cut.axis]) < 0) continue;   // on the half that's cut away
            pts.push(v);
          }
        });
        return pts;
      });
    }
    function placeCamera(t) {
      if (camTween) {
        const u = Math.min(1, (t - camTween.t0) / camTween.dur), e = ease(u);
        cam.baseAz = camTween.az0 + (camTween.az1 - camTween.az0) * e;
        cam.el = camTween.el0 + (camTween.el1 - camTween.el0) * e;
        if (u >= 1) camTween = null;
      }
      let az = cam.baseAz;
      const idle = (t - lastInteract) > 5;
      if (cam.spin) { cam.baseAz += cam.spin / 60; az = cam.baseAz; }
      else if (cam.sway && idle) az = cam.baseAz + Math.sin(t * 0.35) * 0.32;
      cam.az += (az - cam.az) * 0.08;
      cam.target.lerp(cam.goalTarget, 0.05);
      cam.dist += (cam.goalDist - cam.dist) * 0.05;
      const p = new T.Vector3(Math.cos(cam.el) * Math.sin(cam.az), Math.sin(cam.el), Math.cos(cam.el) * Math.cos(cam.az)).multiplyScalar(cam.dist).add(cam.target);
      camera.position.copy(p); camera.lookAt(cam.target);
    }

    // ---------- callout tags ----------
    function project(v) {
      const p = v.clone().project(camera);
      return [(p.x + 1) / 2 * W(), (1 - p.y) / 2 * H(), p.z];
    }
    // Where a tag's leader line ends: on the part's visible surface (not its hidden center). The point is
    // kept in the part's parent frame, so it moves with the part (and swings with a hinge) but doesn't
    // whirl around when the part itself spins.
    const ray = new T.Raycaster();
    function anchorOf(L) {
      const tg = L.target;
      if (!tg || !tg.isObject3D) return worldPoint(tg);
      if (!tg.parent) return null;                                   // removed
      if (!L.anchor && !intros.some(a => isInside(tg, a.o))) {
        const c = boxOf(tg).getCenter(new T.Vector3());
        ray.set(camera.position, c.clone().sub(camera.position).normalize());
        const hits = ray.intersectObject(tg, true).filter(h => h.object.isMesh && !h.object.userData.helper && h.object.visible);
        const p = hits.length ? hits[0].point : c;
        L.anchor = { frame: tg.parent, local: tg.parent.worldToLocal(p.clone()) };
      }
      return L.anchor ? L.anchor.frame.localToWorld(L.anchor.local.clone()) : worldPoint(tg);
    }
    function fadeLabel(L) {
      if (L.gone) return;
      L.gone = true;                                   // updateLabels hides it (the CSS fades it) and leaves its slot free
      setTimeout(() => kit.remove(L), 400);
    }
    function updateLabels(t) {
      const cx = W() / 2, gap = 8, items = [];
      for (const L of labels) {
        const w = anchorOf(L);
        const p = w ? project(w) : [0, 0, 2];
        const visible = !L.gone && !!w && p[2] < 1 && t > L.delay;
        L.tag.style.opacity = visible ? 1 : 0;
        L.line.style.opacity = L.dot.style.opacity = visible ? 1 : 0;
        if (!visible) continue;
        if (!L.side) L.side = p[0] < cx ? 'left' : 'right';           // decided once, so tags don't flip sides
        items.push({ L, p, w: L.tag.offsetWidth, h: L.tag.offsetHeight });
      }
      // Each side is a column: tags keep the order of their parts from top to bottom and never overlap.
      for (const side of ['left', 'right']) {
        const col = items.filter(i => i.L.side === side).sort((a, b) => a.p[1] - b.p[1]);
        let y = -1e9;
        for (const i of col) { i.y = Math.max(i.p[1] - i.h / 2 - 24, y); y = i.y + i.h + gap; }
        const over = col.length ? col[col.length - 1].y + col[col.length - 1].h + 6 - H() : 0;
        if (over > 0) for (const i of col) i.y -= over;
        for (const i of col) i.y = Math.max(6, i.y);
      }
      // Tags from the two columns can still collide (a tag clamped at the screen edge): push them apart.
      items.sort((a, b) => a.y - b.y);
      for (let i = 0; i < items.length; i++) {
        const A = items[i], ax = A.L.side === 'left' ? A.p[0] - 80 - A.w : A.p[0] + 80;
        for (let j = i + 1; j < items.length; j++) {
          const B = items[j], bx = B.L.side === 'left' ? B.p[0] - 80 - B.w : B.p[0] + 80;
          if (ax < bx + B.w && bx < ax + A.w && B.y < A.y + A.h + gap) B.y = A.y + A.h + gap;
        }
      }
      for (const { L, p, w, h, y } of items) {
        let x = L.side === 'left' ? p[0] - 80 - w : p[0] + 80;
        x = Math.max(6, Math.min(W() - w - 6, x));
        if (L.x === null) { L.x = x; L.y = y; } else { L.x += (x - L.x) * 0.25; L.y += (y - L.y) * 0.25; }
        L.tag.style.transform = `translate(${L.x}px, ${L.y}px)`;
        const ex = L.side === 'left' ? L.x + w : L.x, ey = L.y + h / 2;
        L.line.setAttribute('x1', ex); L.line.setAttribute('y1', ey); L.line.setAttribute('x2', p[0]); L.line.setAttribute('y2', p[1]);
        L.dot.setAttribute('cx', p[0]); L.dot.setAttribute('cy', p[1]);
      }
    }

    // ---------- loop ----------
    function frame(now) {
      const t = (now - t0) / 1000, dt = Math.min(0.05, (now - last) / 1000); last = now;
      clock = t;
      for (const fn of anims) { try { fn(t, dt); } catch (e) {} }
      for (let i = intros.length - 1; i >= 0; i--) {
        const a = intros[i], u = Math.min(1, Math.max(0, (t - a.t0) / a.dur));
        // The model's code changed this part while it was still dropping in ("fan.position.y = 2"):
        // finish now and keep that change.
        if (a.appliedS && (!a.o.scale.equals(a.appliedS) || a.o.position.y !== a.appliedY)) {
          if (a.o.scale.equals(a.appliedS)) a.o.scale.copy(a.s);
          if (a.o.position.y === a.appliedY) a.o.position.y = a.y;
          intros.splice(i, 1); continue;
        }
        const e = easeBack(u);
        a.o.scale.copy(a.s).multiplyScalar(Math.max(0.0001, Math.min(1.08, e)));
        a.o.position.y = a.y + a.lift * (1 - Math.min(1, u * 1.15));
        if (u >= 1) { a.o.scale.copy(a.s); a.o.position.y = a.y; intros.splice(i, 1); continue; }
        a.appliedS = a.o.scale.clone(); a.appliedY = a.o.position.y;
      }
      const live = timers.slice();
      for (const w of live) {
        let u = (t - w.t0) / w.dur;
        if (u < 0) continue;
        let done = false;
        if (w.loop) { u = u % 2; u = u > 1 ? 2 - u : u; } else if (u >= 1) { u = 1; done = true; }
        try { w.fn(ease(u), u); } catch (e) {}
        if (done) timers.splice(timers.indexOf(w), 1);
      }
      // Filled faces of cut parts stay on their cutting plane.
      for (const c of capList) {
        const n = c.plane.normal;
        c.cap.position.copy(c.mid).addScaledVector(n, -(n.dot(c.mid) + c.plane.constant));
        c.cap.lookAt(c.cap.position.clone().sub(n));
      }
      placeCamera(t);
      renderer.render(scene, camera);
      updateLabels(t);
      requestAnimationFrame(frame);
    }

    // ---------- drag to rotate, scroll to zoom ----------
    let drag = null;
    renderer.domElement.addEventListener('pointerdown', e => { camTween = null; drag = { x: e.clientX, y: e.clientY, az: cam.baseAz, el: cam.el }; lastInteract = (performance.now() - t0) / 1000; cam.spin = 0; });
    addEventListener('pointermove', e => {
      if (!drag) return;
      cam.baseAz = drag.az - (e.clientX - drag.x) * 0.008;
      cam.az = cam.baseAz;
      cam.el = Math.max(-80 * DEG, Math.min(85 * DEG, drag.el + (e.clientY - drag.y) * 0.006));
      lastInteract = (performance.now() - t0) / 1000;
    });
    addEventListener('pointerup', () => { drag = null; });
    renderer.domElement.addEventListener('wheel', e => { cam.goalDist *= Math.exp(e.deltaY * 0.001); lastInteract = (performance.now() - t0) / 1000; e.preventDefault(); }, { passive: false });
    addEventListener('resize', () => { renderer.setSize(W(), H()); camera.aspect = W() / H(); camera.updateProjectionMatrix(); });

    if (opts.view) kit.view(opts.view);
    return kit;
  };
  window.Kit.split = splitStatements;   // for tests
  window.Kit.hoist = hoist;
})();

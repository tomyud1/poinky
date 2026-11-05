// Poinky's interface sounds, synthesized in layers (a soft tone body, a click or texture on top,
// and a shared room). All notes come from one key (G major pentatonic), so sounds that overlap
// still sound good together. Each helper has its own note, so you can tell them apart by ear.
//
//   const S = new Sounds();             // S.params / S.voices hold every tweakable value
//   S.play('done', {x: 0.8, note: 2});  // x: -1 (left) … 1 (right) on screen
//   const wav = await S.renderWav('done');   // the same sound as a WAV file (Blob)
(function (global) {
  // G major pentatonic, as semitones above G4 (392 Hz): G A B D E G A B D E G
  const SCALE = [0, 2, 4, 7, 9, 12, 14, 16, 19, 21, 24, 26, 28];
  const hz = semis => 392 * Math.pow(2, semis / 12);

  // Every sound and its knobs. vol: loudness, pitch: semitones up/down, bright: tone color (0 dark – 1 bright),
  // length: how long it rings (×), room: how much echo.
  const VOICES = {
    spawn:   { label: 'Helper appears',      vol: .7,  pitch: 0, bright: .6, length: 1, room: .35 },
    handoff: { label: 'Main hands the task', vol: .45,  pitch: 0, bright: .55, length: 1, room: .3 },
    ack:     { label: 'Helper: "On it!"',    vol: .55, pitch: 0, bright: .6, length: 1, room: .25 },
    whoosh:  { label: 'Flight',              vol: .35, pitch: 0, bright: .5, length: 1, room: .2 },
    land:    { label: 'Lands at the edge',   vol: .5,  pitch: 0, bright: .45, length: 1, room: .2 },
    tick:    { label: 'To-do item done',     vol: .4,  pitch: 0, bright: .7, length: 1, room: .35 },
    hand:    { label: 'Raises a hand',       vol: .65, pitch: 0, bright: .55, length: 1, room: .3 },
    done:    { label: 'Task done',           vol: .8,  pitch: 0, bright: .65, length: 1, room: .45 },
    fail:    { label: 'Couldn’t finish',     vol: .55, pitch: 0, bright: .35, length: 1, room: .35 },
    merge:   { label: 'Back into the main',  vol: .55, pitch: 0, bright: .5, length: 1, room: .3 },
    screenOpen:  { label: 'Video opens',     vol: .6,  pitch: 0, bright: .55, length: 1, room: .45 },
    screenClose: { label: 'Video closes',    vol: .5,  pitch: 0, bright: .5, length: 1, room: .4 },
  };

  class Sounds {
    constructor() {
      this.params = { master: .8, room: .5, key: 0, muted: false };
      this.voices = JSON.parse(JSON.stringify(VOICES));
      this.ctx = null;
    }

    static get scale() { return SCALE; }
    static get names() { return Object.keys(VOICES); }

    // The audio graph: master → compressor → speakers, plus a shared room (reverb).
    setup(ctx, dest) {
      const g = { ctx, master: ctx.createGain(), comp: ctx.createDynamicsCompressor(), verb: ctx.createConvolver(), verbIn: ctx.createGain() };
      g.comp.threshold.value = -14; g.comp.knee.value = 10; g.comp.ratio.value = 3; g.comp.attack.value = .003; g.comp.release.value = .15;
      g.master.gain.value = this.params.master;
      g.verb.buffer = this.impulse(ctx, 1.9);
      g.verbIn.gain.value = this.params.room;
      g.verbIn.connect(g.verb); g.verb.connect(g.master);
      g.master.connect(g.comp); g.comp.connect(dest || ctx.destination);
      return g;
    }

    impulse(ctx, secs) {
      const n = Math.floor(ctx.sampleRate * secs), b = ctx.createBuffer(2, n, ctx.sampleRate);
      for (let ch = 0; ch < 2; ch++) {
        const d = b.getChannelData(ch); let lp = 0, seed = ch ? 99 : 7;
        for (let i = 0; i < n; i++) {
          seed = (seed * 1664525 + 1013904223) >>> 0;
          const w = seed / 4294967296 * 2 - 1;
          lp += (w - lp) * (.5 - .35 * i / n);   // darker as it fades
          d[i] = lp * Math.pow(1 - i / n, 3.2) * (i < ctx.sampleRate * .008 ? i / (ctx.sampleRate * .008) : 1);
        }
      }
      return b;
    }

    live() {
      if (!this.ctx) { this.ctx = new (window.AudioContext || window.webkitAudioContext)(); this.g = this.setup(this.ctx); }
      if (this.ctx.state === 'suspended') this.ctx.resume();
      this.g.master.gain.value = this.params.muted ? 0 : this.params.master;
      this.g.verbIn.gain.value = this.params.room;
      return this.g;
    }

    play(name, o = {}) {
      if (this.params.muted || !VOICES[name]) return;
      const g = this.live();
      this.voice(g, name, g.ctx.currentTime + .005, o);
    }

    // ---------- building blocks ----------

    // One sound's own path: its volume and tone, panned, with a send to the room.
    bus(g, v, pan, t) {
      const ctx = g.ctx, gain = ctx.createGain(), tone = ctx.createBiquadFilter(), p = ctx.createStereoPanner(), send = ctx.createGain();
      gain.gain.value = v.vol;
      tone.type = 'lowpass'; tone.frequency.value = 1200 + Math.pow(v.bright, 1.6) * 14000; tone.Q.value = .4;
      p.pan.setValueAtTime(Math.max(-1, Math.min(1, pan || 0)) * .75, t);
      send.gain.value = v.room;
      gain.connect(tone); tone.connect(p); p.connect(g.master); p.connect(send); send.connect(g.verbIn);
      return { in: gain, pan: p };
    }

    // A bell: a sine whose brightness (FM) fades faster than its body.
    bell(g, out, t, f, dur, amp, ratio = 2, index = 2.2) {
      const ctx = g.ctx, car = ctx.createOscillator(), mod = ctx.createOscillator(), mg = ctx.createGain(), env = ctx.createGain();
      car.frequency.value = f; mod.frequency.value = f * ratio;
      mg.gain.setValueAtTime(f * index, t); mg.gain.exponentialRampToValueAtTime(f * .02, t + dur * .5);
      env.gain.setValueAtTime(0, t); env.gain.linearRampToValueAtTime(amp, t + .004);
      env.gain.exponentialRampToValueAtTime(.0001, t + dur);
      mod.connect(mg); mg.connect(car.frequency); car.connect(env); env.connect(out);
      car.start(t); mod.start(t); car.stop(t + dur + .05); mod.stop(t + dur + .05);
    }

    // A soft mallet (marimba-like): a round fundamental plus a quick overtone.
    mallet(g, out, t, f, dur, amp) {
      const ctx = g.ctx;
      [[1, 1, dur], [3.98, .28, dur * .22], [9.9, .06, dur * .06]].forEach(([m, a, d]) => {
        const o = ctx.createOscillator(), e = ctx.createGain();
        o.frequency.value = f * m; o.type = 'sine';
        e.gain.setValueAtTime(0, t); e.gain.linearRampToValueAtTime(amp * a, t + .003);
        e.gain.exponentialRampToValueAtTime(.0001, t + Math.max(.03, d));
        o.connect(e); e.connect(out); o.start(t); o.stop(t + d + .05);
      });
    }

    // A pitch glide with a soft envelope ("bloop").
    glide(g, out, t, f0, f1, dur, amp, type = 'sine') {
      const ctx = g.ctx, o = ctx.createOscillator(), e = ctx.createGain();
      o.type = type; o.frequency.setValueAtTime(f0, t); o.frequency.exponentialRampToValueAtTime(f1, t + dur * .7);
      e.gain.setValueAtTime(0, t); e.gain.linearRampToValueAtTime(amp, t + .012);
      e.gain.exponentialRampToValueAtTime(.0001, t + dur);
      o.connect(e); e.connect(out); o.start(t); o.stop(t + dur + .05);
    }

    // Filtered noise: clicks, air, sparkle.
    noise(g, out, t, dur, amp, { type = 'highpass', f = 3000, f1, q = .7 } = {}) {
      const ctx = g.ctx, n = Math.ceil(ctx.sampleRate * dur), b = ctx.createBuffer(1, n, ctx.sampleRate), d = b.getChannelData(0);
      let s = 12345;
      for (let i = 0; i < n; i++) { s = (s * 1664525 + 1013904223) >>> 0; d[i] = s / 4294967296 * 2 - 1; }
      const src = ctx.createBufferSource(), flt = ctx.createBiquadFilter(), e = ctx.createGain();
      src.buffer = b; flt.type = type; flt.Q.value = q;
      flt.frequency.setValueAtTime(f, t); if (f1) flt.frequency.exponentialRampToValueAtTime(f1, t + dur);
      e.gain.setValueAtTime(0, t); e.gain.linearRampToValueAtTime(amp, t + Math.min(.004, dur / 3));
      e.gain.exponentialRampToValueAtTime(.0001, t + dur);
      src.connect(flt); flt.connect(e); e.connect(out); src.start(t); src.stop(t + dur + .02);
    }

    // ---------- the sounds ----------

    voice(g, name, t, o = {}) {
      const v = this.voices[name], L = v.length, key = this.params.key + v.pitch;
      const n = s => hz(s + key);
      const own = SCALE[((o.note || 0) % 5 + 5) % 5];   // this helper's note
      const b = this.bus(g, v, o.x, t), out = b.in;
      switch (name) {
        case 'spawn':   // a soft "bloop" up, then a small glassy "ting"
          this.glide(g, out, t, n(-5), n(12), .22 * L, .32);
          this.noise(g, out, t, .012, .05, { f: 5000 });
          this.bell(g, out, t + .07, n(12 + own), .5 * L, .11, 2, 1.6);
          this.bell(g, out, t + .1, n(19 + own), .45 * L, .06, 3, 1.2);
          break;
        case 'handoff':   // two friendly notes: "here you go"
          this.mallet(g, out, t, n(7), .45 * L, .3);
          this.mallet(g, out, t + .1, n(12), .6 * L, .26);
          break;
        case 'ack':   // the helper's own little "on it" in its note
          this.mallet(g, out, t, n(12 + own), .28 * L, .22);
          this.noise(g, out, t, .01, .04, { type: 'bandpass', f: 2400, q: 2 });
          break;
        case 'whoosh': {   // air that moves across the speakers with the flight
          const dur = Math.max(.25, (o.dur || .8) * L);
          this.noise(g, out, t, dur, .85, { type: 'bandpass', f: 380, f1: 1900, q: 1.1 });
          if (o.x2 !== undefined) {
            b.pan.pan.setValueAtTime(Math.max(-1, Math.min(1, o.x)) * .75, t);
            b.pan.pan.linearRampToValueAtTime(Math.max(-1, Math.min(1, o.x2)) * .75, t + dur);
          }
          break;
        }
        case 'land':   // a soft touch-down
          this.glide(g, out, t, 190, 95, .14 * L, .26);
          this.mallet(g, out, t + .01, n(24 + own), .16 * L, .06);
          break;
        case 'tick':   // a tiny bright "plink"
          this.bell(g, out, t, n(24 + own), .35 * L, .26, 3.5, 1.1);
          break;
        case 'hand':   // "excuse me?": two notes rising, like a question
          this.mallet(g, out, t, n(7), .32 * L, .26);
          this.mallet(g, out, t + .16, n(14), .55 * L, .28);
          this.bell(g, out, t + .16, n(26), .7 * L, .04, 2, 1.4);
          break;
        case 'done': {   // the satisfying one: a quick rising chord that blooms into a shimmer
          [0, 4, 7, 12].forEach((s, i) => this.mallet(g, out, t + i * .052, n(s), .7 * L, .24 - i * .02));
          this.bell(g, out, t + .2, n(24), 1.5 * L, .09, 2, 1.8);
          this.bell(g, out, t + .23, n(28), 1.3 * L, .055, 3, 1.3);
          this.noise(g, out, t + .18, .5 * L, .025, { f: 7000 });
          break;
        }
        case 'fail':   // gentle and low: two soft notes falling
          this.mallet(g, out, t, n(2), .5 * L, .22);
          this.mallet(g, out, t + .17, n(-3), .8 * L, .22);
          break;
        case 'screenOpen': {   // air rising as the card grows, a chord opening up, a soft shimmer when it fills the screen
          const dur = 1.05 * L;
          this.noise(g, out, t, dur, .5, { type: 'bandpass', f: 320, f1: 2600, q: 1.2 });
          if (o.x2 !== undefined) {
            b.pan.pan.setValueAtTime(Math.max(-1, Math.min(1, o.x || 0)) * .75, t);
            b.pan.pan.linearRampToValueAtTime(Math.max(-1, Math.min(1, o.x2)) * .75, t + .7);
          }
          this.glide(g, out, t, n(-17), n(-12), .7 * L, .22);
          [0, 4, 7, 12].forEach((s, i) => this.mallet(g, out, t + .08 + i * .075, n(s), .9 * L, .2 - i * .025));
          this.bell(g, out, t + .55, n(24), 1.4 * L, .07, 2, 1.6);
          this.bell(g, out, t + .6, n(31), 1.1 * L, .035, 3, 1.2);
          break;
        }
        case 'screenClose': {   // the same, folding back down into the buddy
          const dur = .75 * L;
          this.noise(g, out, t, dur, .42, { type: 'bandpass', f: 2200, f1: 300, q: 1.2 });
          if (o.x2 !== undefined) {
            b.pan.pan.setValueAtTime(Math.max(-1, Math.min(1, o.x || 0)) * .75, t);
            b.pan.pan.linearRampToValueAtTime(Math.max(-1, Math.min(1, o.x2)) * .75, t + .6);
          }
          [12, 7, 4, 0].forEach((s, i) => this.mallet(g, out, t + i * .065, n(s), .6 * L, .17 - i * .02));
          this.glide(g, out, t + .3, n(0), n(-12), .35 * L, .2);
          break;
        }
        case 'merge':   // a small "bloop" down into the main buddy
          this.glide(g, out, t, n(12), n(0), .2 * L, .26);
          this.bell(g, out, t + .12, n(12 + own), .5 * L, .06, 2, 1.2);
          break;
      }
    }

    // ---------- files ----------

    // Renders a sound offline (same settings) and returns a WAV Blob.
    async renderWav(name, o = {}) {
      const rate = 48000, secs = 3.2;
      const ctx = new OfflineAudioContext(2, rate * secs, rate);
      const g = this.setup(ctx);
      g.master.gain.value = this.params.master;
      this.voice(g, name, .02, Object.assign({ x: 0 }, o));
      const buf = await ctx.startRendering();
      // Trim the silence at the end.
      const L = buf.getChannelData(0), R = buf.getChannelData(1);
      let end = buf.length - 1;
      while (end > rate * .3 && Math.abs(L[end]) < 1e-4 && Math.abs(R[end]) < 1e-4) end--;
      end = Math.min(buf.length, end + Math.floor(rate * .05));
      return wav([L.subarray(0, end), R.subarray(0, end)], rate);
    }
  }

  function wav(chans, rate) {
    const n = chans[0].length, nc = chans.length, data = new DataView(new ArrayBuffer(44 + n * nc * 2));
    const str = (o, s) => { for (let i = 0; i < s.length; i++) data.setUint8(o + i, s.charCodeAt(i)); };
    str(0, 'RIFF'); data.setUint32(4, 36 + n * nc * 2, true); str(8, 'WAVE'); str(12, 'fmt ');
    data.setUint32(16, 16, true); data.setUint16(20, 1, true); data.setUint16(22, nc, true); data.setUint32(24, rate, true);
    data.setUint32(28, rate * nc * 2, true); data.setUint16(32, nc * 2, true); data.setUint16(34, 16, true);
    str(36, 'data'); data.setUint32(40, n * nc * 2, true);
    let o = 44;
    for (let i = 0; i < n; i++) for (let c = 0; c < nc; c++) {
      const s = Math.max(-1, Math.min(1, chans[c][i])); data.setInt16(o, s < 0 ? s * 0x8000 : s * 0x7fff, true); o += 2;
    }
    return new Blob([data], { type: 'audio/wav' });
  }

  global.Sounds = Sounds;
})(window);

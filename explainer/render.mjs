// Renders moments of an explainer video into one PNG sheet with headless Chrome.
// Usage: node render.mjs <video dir> <out.png> <t1,t2,...> [scenes=s2] [file_s2=scenes/s2.v2.js] [cols=3] [w=520]
// Prints {"errors":[...], "lint":[...]} as JSON: scene exceptions / unknown cues, and layout problems (text cropped, tiny, overlapping).
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const [videoDir, outPng, times, ...rest] = process.argv.slice(2);
const extra = new URLSearchParams(rest.map(a => a.split('=')));
const chromePath = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const prof = mkdtempSync(join(tmpdir(), 'poinky-explainer-'));
const port = 9800 + Math.floor(Math.random() * 1000);
const chrome = spawn(chromePath, ['--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${prof}`,
  '--allow-file-access-from-files', '--hide-scrollbars', '--force-device-scale-factor=1', 'about:blank'], { stdio: 'ignore' });
const sleep = ms => new Promise(r => setTimeout(r, ms));
const done = (code, obj) => { console.log(JSON.stringify(obj)); chrome.kill(); try { rmSync(prof, { recursive: true, force: true }); } catch {} process.exit(code); };

let ws, opened;
for (let i = 0; i < 80 && !ws; i++) {
  try {
    const t = await (await fetch(`http://127.0.0.1:${port}/json`, { signal: AbortSignal.timeout(2000) })).json();
    const p = t.find(x => x.type === 'page');
    if (p) { ws = new WebSocket(p.webSocketDebuggerUrl); opened = new Promise(r => ws.onopen = r); break; }
  } catch {}
  await sleep(150);
}
if (!ws) done(2, { errors: ['Chrome did not start'] });
await opened;
let id = 0; const pending = new Map();
ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result); pending.delete(m.id); } };
const send = (method, params = {}) => new Promise(r => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });

const cols = +(extra.get('cols') || 3), w = +(extra.get('w') || 520);
await send('Emulation.setDeviceMetricsOverride', { width: cols * w, height: 1200, deviceScaleFactor: 1, mobile: false });
const qs = new URLSearchParams({ grid: '1', dir: 'file://' + resolve(videoDir), times, cols: String(cols), w: String(w) });
for (const [k, v] of extra) qs.set(k, v);
await send('Page.enable');
await send('Page.navigate', { url: 'file://' + join(here, 'player.html') + '?' + qs });
let r = null;
for (let i = 0; i < 120 && !r; i++) { await sleep(100); r = (await send('Runtime.evaluate', { expression: 'window.renderDone', returnByValue: true })).result?.value; }
if (!r) done(1, { errors: ['the page did not finish rendering'] });
const shot = await send('Page.captureScreenshot', { format: 'png', clip: { x: 0, y: 0, width: r.w, height: r.h, scale: 1 }, captureBeyondViewport: true });
writeFileSync(outPng, Buffer.from(shot.data, 'base64'));
done(0, { errors: r.errors, lint: r.lint || [] });

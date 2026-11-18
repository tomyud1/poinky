// Renders a page the way a Mac screen shows it (2x pixels) and says where phrases on it are, so the
// snapping test can check marks against the real text. Usage:
//   node render.mjs page.html out.png width height '["phrase" or "#id", …]'   → out.png + out.png.json ({phrase: [x,y,w,h]} in points)
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
const [page, out, W, H, phrasesJSON] = process.argv.slice(2);
const chromePath = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const prof = mkdtempSync(join(tmpdir(), 'poinky-snap-'));
const port = 9800 + Math.floor(Math.random() * 150);
const chrome = spawn(chromePath, ['--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${prof}`, '--hide-scrollbars', 'about:blank'], { stdio: 'ignore' });
const sleep = ms => new Promise(r => setTimeout(r, ms));
let ws, opened;
for (let i = 0; i < 60 && !ws; i++) {
  try {
    const t = await (await fetch(`http://127.0.0.1:${port}/json`, { signal: AbortSignal.timeout(2000) })).json();
    const p = t.find(x => x.type === 'page');
    if (p) { ws = new WebSocket(p.webSocketDebuggerUrl); opened = new Promise(r => ws.onopen = r); break; }
  } catch {}
  await sleep(250);
}
if (!ws) { console.error('Chrome did not start'); chrome.kill(); process.exit(2); }
await opened;
let id = 0; const pending = new Map();
ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result); pending.delete(m.id); } };
const send = (method, params = {}) => new Promise(r => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
await send('Page.enable');
await send('Emulation.setDeviceMetricsOverride', { width: +W, height: +H, deviceScaleFactor: 2, mobile: false });
await send('Page.navigate', { url: 'file://' + resolve(page) });
await sleep(1200);
const find = `(${function (phrases) {
  // The page's text with each character's node, so a phrase can span tags (<b>, <br>…).
  const chars = [];
  const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let n; (n = walk.nextNode());) for (let i = 0; i < n.data.length; i++) chars.push([n, i]);
  const norm = c => /\s/.test(c) ? ' ' : c;
  const text = chars.map(([n, i]) => norm(n.data[i])).join('');
  const out = {};
  for (const p of phrases) {
    // "#id": an element (a checkbox, an icon) instead of text.
    if (p.startsWith('#')) { const e = document.querySelector(p); const b = e && e.getBoundingClientRect(); out[p] = b ? [b.left, b.top, b.width, b.height] : null; continue; }
    const at = text.indexOf(p);
    if (at < 0) { out[p] = null; continue; }
    const r = document.createRange();
    r.setStart(chars[at][0], chars[at][1]);
    const [en, ei] = chars[at + p.length - 1]; r.setEnd(en, ei + 1);
    // Union of the line boxes (a <br> in the phrase makes several).
    let x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9;
    for (const b of r.getClientRects()) { if (!b.width) continue; x0 = Math.min(x0, b.left); y0 = Math.min(y0, b.top); x1 = Math.max(x1, b.right); y1 = Math.max(y1, b.bottom); }
    out[p] = [x0, y0, x1 - x0, y1 - y0];
  }
  return out;
}})(${phrasesJSON})`;
const rects = (await send('Runtime.evaluate', { expression: find, returnByValue: true })).result.value;
const shot = await send('Page.captureScreenshot', { format: 'png' });
writeFileSync(out, Buffer.from(shot.data, 'base64'));
writeFileSync(out + '.json', JSON.stringify(rects));
chrome.kill(); try { rmSync(prof, { recursive: true, force: true }); } catch {}

// Pictures of the reading bubble (tools/tests/quiet-bubble.html?shot=…) in headless Chrome, in real time (rAF runs, so
// the buddy is placed), light and dark, and one with Reduced Motion. Usage: node tools/quiet-test/shots.mjs <outdir>
import { spawn } from 'node:child_process';
import { mkdtempSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const out = resolve(process.argv[2] || 'shots'); mkdirSync(out, { recursive: true });
const chrome = spawn(process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  ['--headless=new', '--remote-debugging-port=9377', `--user-data-dir=${mkdtempSync(join(tmpdir(), 'qshot-'))}`, '--allow-file-access-from-files', 'about:blank'], { stdio: 'ignore' });
const sleep = ms => new Promise(r => setTimeout(r, ms));
let ws, opened;
for (let i = 0; i < 60 && !ws; i++) {
  try { const t = await (await fetch('http://127.0.0.1:9377/json')).json(); const p = t.find(x => x.type === 'page');
        if (p) { ws = new WebSocket(p.webSocketDebuggerUrl); opened = new Promise(r => ws.onopen = r); break; } } catch {}
  await sleep(250);
}
await opened;
let id = 0; const pend = new Map();
ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && pend.has(m.id)) { pend.get(m.id)(m.result); pend.delete(m.id); } };
const send = (method, params = {}) => new Promise(r => { const i = ++id; pend.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
await send('Page.enable');
await send('Emulation.setDeviceMetricsOverride', { width: 1000, height: 700, deviceScaleFactor: 2, mobile: false });
const page = 'file://' + resolve(here, '../tests/quiet-bubble.html');
async function shot(name, q, reduced = false) {
  await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-reduced-motion', value: reduced ? 'reduce' : 'no-preference' }] });
  await send('Page.navigate', { url: `${page}?${q}` });
  for (let i = 0; i < 80; i++) { await sleep(150); const r = await send('Runtime.evaluate', { expression: 'document.title', returnByValue: true }); if (r.result.value === 'SHOT') break; }
  await sleep(700);
  const { data } = await send('Page.captureScreenshot', { format: 'png' });
  writeFileSync(join(out, name + '.png'), Buffer.from(data, 'base64'));
}
for (const s of ['reading', 'long', 'copy', 'hover', 'hebrew', 'snip']) for (const bg of ['light', 'dark']) await shot(`bubble-${s}-${bg}`, `shot=${s}&bg=${bg}`);
await shot('bubble-long-reduced', 'shot=long', true);
chrome.kill();
console.log('saved to', out);
process.exit(0);

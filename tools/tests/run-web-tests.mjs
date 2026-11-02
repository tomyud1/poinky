// Runs the browser tests in tools/tests/*.html in headless Chrome and prints their results.
// Usage: node tools/tests/run-web-tests.mjs   (needs Google Chrome; Node 22+ for WebSocket)
import { spawn } from 'node:child_process';
import { mkdtempSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const chromePath = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const prof = mkdtempSync(join(tmpdir(), 'poinky-webtest-'));
const port = 9400 + Math.floor(Math.random() * 400);
const chrome = spawn(chromePath, ['--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${prof}`, '--allow-file-access-from-files', 'about:blank'], { stdio: 'ignore' });
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
if (!ws) { console.log('Chrome did not start'); chrome.kill(); process.exit(2); }
await opened;
let id = 0; const pending = new Map();
ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result); pending.delete(m.id); } };
const send = (method, params = {}) => new Promise(r => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
await send('Page.enable');
let failed = false;
for (const f of readdirSync(here).filter(f => f.endsWith('.html')).sort()) {
  await send('Page.navigate', { url: 'file://' + join(here, f) });
  let r = null;
  for (let i = 0; i < 80 && !r; i++) { await sleep(250); r = (await send('Runtime.evaluate', { expression: 'window.testResults', returnByValue: true })).result?.value; }
  console.log(f);
  if (!r) { console.log('  FAIL did not finish'); failed = true; continue; }
  for (const l of r.lines) console.log('  ' + l);
  if (!r.pass) failed = true;
}
chrome.kill(); try { rmSync(prof, { recursive: true, force: true }); } catch {}
process.exit(failed ? 1 : 0);

// Plays a teacher reply in tools/lesson-player.html (headless Chrome) and saves a picture at the end of every
// spoken line, plus final.png when the drawing is done.
// Usage: node tools/lesson-shots.mjs reply.txt outdir [--bg light|dark|code] [--size 1512x982] [--speed 1]
// Also saves saved.png: the picture the paper's Save button makes.
import { spawn } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const [replyPath, outDir] = args.filter((a, i) => !a.startsWith('--') && !(i && args[i - 1].startsWith('--')));
const bg = opt('--bg', 'light'), [W, H] = opt('--size', '1512x982').split('x').map(Number), speed = +opt('--speed', '1');
mkdirSync(outDir, { recursive: true });
const chromePath = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const prof = mkdtempSync(join(tmpdir(), 'poinky-lesson-'));
const port = 9800 + Math.floor(Math.random() * 150);
const chrome = spawn(chromePath, ['--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${prof}`, '--allow-file-access-from-files', '--hide-scrollbars', 'about:blank'], { stdio: 'ignore' });
const sleep = ms => new Promise(r => setTimeout(r, ms));
let ws, opened;
for (let i = 0; i < 60 && !ws; i++) {
  try {
    const t = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
    const p = t.find(x => x.type === 'page');
    if (p) { ws = new WebSocket(p.webSocketDebuggerUrl); opened = new Promise(r => ws.onopen = r); }
  } catch {}
  await sleep(250);
}
await opened;
let id = 0; const pending = new Map();
ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result); pending.delete(m.id); } };
const send = (method, params = {}) => new Promise(r => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async expr => (await send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: false })).result?.value;
await send('Page.enable');
await send('Emulation.setDeviceMetricsOverride', { width: W, height: H, deviceScaleFactor: 1, mobile: false });
await send('Page.navigate', { url: 'file://' + resolve(here, 'lesson-player.html') + '?bg=' + bg });
for (let i = 0; i < 40 && !(await ev('!!(document.getElementById("overlay").contentWindow.SB && document.getElementById("overlay").contentWindow.SB.lessonBegin)')); i++) await sleep(100);
const reply = readFileSync(replyPath, 'utf8');
await ev(`lab.play(${JSON.stringify(reply)}, {speed:${speed}})`);
const shot = async name => { const r = await send('Page.captureScreenshot', { format: 'png' }); writeFileSync(join(outDir, name), Buffer.from(r.data, 'base64')); };
let seen = 1, n = 0;
for (let t = 0; t < 240000; t += 100) {
  await sleep(100);
  const len = await ev('lab.log.length'), done = await ev('!!lab.done');
  if (len > seen) { seen = len; await shot(`line${String(++n).padStart(2, '0')}.png`); }
  if (done) break;
}
// The last line has been said; the drawing may still be catching up. final.png is when it's done and the pen
// has had time to go (2.5 s), so a pen left behind shows.
for (let i = 0; i < 600 && await ev('document.getElementById("overlay").contentWindow.SB.lessonBusy()'); i++) await sleep(100);
await sleep(3000);
await shot('final.png');
const pic = (await send('Runtime.evaluate', { expression: 'document.getElementById("overlay").contentWindow.SB.lessonPicture()', awaitPromise: true, returnByValue: true })).result?.value;
if (pic && pic.png) writeFileSync(join(outDir, 'saved.png'), Buffer.from(pic.png.split(',')[1], 'base64'));
else console.log('no picture', pic && Object.keys(pic));
writeFileSync(join(outDir, 'log.txt'), (await ev('lab.log.join("\\n")')) + '\n');
console.log(await ev('lab.log.join("\\n")'));
chrome.kill(); try { rmSync(prof, { recursive: true, force: true }); } catch {}
process.exit(0);

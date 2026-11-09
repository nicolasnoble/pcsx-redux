// Tests of the web view's rich editor (translate-web.js) in headless Chromium,
// driven over the DevTools protocol with nothing but Node (22 or later).
//
//   VP_EDITABLE_OUT=/tmp/editable.jsonl VP_DISC1=<disc.cue> \
//       pcsx-redux -cli -dofile examples/vp/preview-test.lua
//   node examples/vp/translate-web-test.mjs /tmp/editable.jsonl [shots-dir]
//
// 1. Every string of the corpus, text -> chips -> text, comes back identical,
//    and rendering that text again gives the same chips.
// 2. Backspace after a chip removes the whole chip, and typing with the caret
//    on a chip never changes the chip's tag.
// 3. Spellcheck: a misspelled French word in the lang=fr editor is underlined
//    and the same word with spellcheck off is not (counted as red pixels under
//    the word in a screenshot). Chromium needs its French dictionary for that;
//    a run where it never loads reports the check as not measurable.
//
// CHROME names the browser (chromium by default). Red arms, each of which
// check 1 must catch: VP_WEB_RED=1 makes the serializer drop the doubling of
// braces (only the added brace strings have any), VP_WEB_RED=2 makes it write
// the end marker as a newline (every corpus string).

import { spawn } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync, mkdirSync, copyFileSync, existsSync } from 'node:fs';
import { tmpdir, homedir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { inflateSync } from 'node:zlib';

const here = dirname(fileURLToPath(import.meta.url));
const corpusPath = process.argv[2];
const shots = process.argv[3];
if (!corpusPath) { console.log('usage: translate-web-test.mjs <editable.jsonl> [shots-dir]'); process.exit(2); }
const corpus = readFileSync(corpusPath, 'utf8').split('\n').filter((l) => l).map((l) => JSON.parse(l));
// The retail strings have no literal braces; these do.
const braces = ['{{}}', 'a{{b}}c{new}\n{{', '}}{pause}x', '{{{spd 2}}}', 'line\n\n'];
const nCorpus = corpus.length;
corpus.push(...braces);
let failures = 0;
const fail = (what) => { failures++; console.log('FAIL ' + what); };

const work = mkdtempSync(join(tmpdir(), 'vp-web-test-'));
const profile = join(work, 'profile');
mkdirSync(join(profile, 'Default'), { recursive: true });
writeFileSync(join(profile, 'Default', 'Preferences'), JSON.stringify({
  spellcheck: { dictionaries: ['fr', 'en-US'], use_spelling_service: false },
  intl: { accept_languages: 'fr,en-US' },
}));
// Reuse dictionaries a desktop Chromium already downloaded, if any.
const dictSrc = join(homedir(), '.config', 'chromium', 'Dictionaries');
if (existsSync(dictSrc)) {
  mkdirSync(join(profile, 'Dictionaries'), { recursive: true });
  for (const f of ['en-US-3-0.bdic', 'fr-FR-3-0.bdic', 'fr-3-0.bdic']) {
    if (existsSync(join(dictSrc, f))) copyFileSync(join(dictSrc, f), join(profile, 'Dictionaries', f));
  }
}
const red = process.env.VP_WEB_RED || '';
const page = join(work, 'test.html');
writeFileSync(page, `<!DOCTYPE html><html><head><meta charset="utf-8"><style>
body { font-family: sans-serif; background: #fff; }
.rich { font-family: monospace; font-size: 18px; white-space: pre-wrap; border: 1px solid #888; width: 700px; min-height: 3em; }
.chip { background: #3d5a80; color: #fff; border-radius: 3px; padding: 0 3px; }
</style><script src="file://${join(here, 'translate-web.js')}"></script></head><body>
<div id="scratch" class="rich"></div>
<div class="rich-pair"><textarea id="ta"></textarea><div id="ed" class="rich" contenteditable="true" lang="fr" spellcheck="true"></div></div>
<p>spellcheck on, lang=fr:</p><div id="sp" class="rich" contenteditable="true" lang="fr" spellcheck="true"></div>
<p>spellcheck off:</p><div id="sp0" class="rich" contenteditable="true" lang="fr" spellcheck="false"></div>
${red === '1' ? '<script>VPRich.serializeOrig = VPRich.serialize; VPRich.serialize = function (el) { return VPRich.serializeOrig(el).replace(/\\{\\{/g, "{").replace(/\\}\\}/g, "}"); };</script>' : ''}
${red === '2' ? '<script>VPRich.serializeOrig = VPRich.serialize; VPRich.serialize = function (el) { return VPRich.serializeOrig(el) + (el.querySelector("br[data-end]") ? "\\n" : ""); };</script>' : ''}
</body></html>`);

const port = 9300 + (process.pid % 500);
const chrome = spawn(process.env.CHROME || 'chromium', ['--headless', '--no-sandbox', '--disable-gpu',
  `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, '--window-size=900,700',
  '--allow-file-access-from-files', '--lang=fr', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
let chromeLog = '';
chrome.stderr.on('data', (d) => { chromeLog += d; });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let target;
for (let i = 0; i < 100 && !target; i++) {
  await sleep(200);
  try { target = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find((t) => t.type === 'page'); } catch { }
}
if (!target) { console.log('FAIL chromium did not start\n' + chromeLog); process.exit(1); }
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener('open', r));
let nextId = 1;
const pending = new Map();
ws.addEventListener('message', (ev) => {
  const m = JSON.parse(ev.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
});
const send = (method, params = {}) => new Promise((resolve, reject) => {
  const id = nextId++;
  pending.set(id, (m) => (m.error ? reject(new Error(method + ': ' + m.error.message)) : resolve(m.result)));
  ws.send(JSON.stringify({ id, method, params }));
});
const evaluate = async (expr) => {
  const r = await send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text);
  return r.result.value;
};
const key = async (k, code, vk, text) => {
  await send('Input.dispatchKeyEvent', { type: 'keyDown', key: k, code, windowsVirtualKeyCode: vk, text });
  await send('Input.dispatchKeyEvent', { type: 'keyUp', key: k, code, windowsVirtualKeyCode: vk });
};

await send('Page.enable');
await send('Page.navigate', { url: 'file://' + page });
for (let i = 0; i < 50 && !(await evaluate('typeof VPRich !== "undefined" && !!document.getElementById("sp0")').catch(() => false)); i++) await sleep(100);

// 1. Round trip over the corpus.
const rt = await evaluate(`(() => {
  const corpus = ${JSON.stringify(corpus)};
  const el = document.getElementById('scratch');
  let bad = [], chips = 0;
  for (let i = 0; i < corpus.length; i++) {
    const t = corpus[i];
    const e = VPRich.render(el, t);
    if (e) { bad.push([i, 'render: ' + e.error]); continue; }
    chips += el.querySelectorAll('.chip').length;
    const h1 = el.innerHTML;
    const back = VPRich.serialize(el);
    if (back !== t) { bad.push([i, 'text differs: ' + JSON.stringify(back).slice(0, 120)]); continue; }
    VPRich.render(el, back);
    if (el.innerHTML !== h1) bad.push([i, 'chips differ']);
  }
  return { n: corpus.length, chips, bad: bad.slice(0, 10), nbad: bad.length };
})()`);
console.log(`round trip: ${nCorpus} corpus strings and ${braces.length} with braces, ${rt.chips} chips, ${rt.nbad} differ`);
for (const b of rt.bad) console.log(`  #${b[0]} ${JSON.stringify(corpus[b[0]]).slice(0, 80)}: ${b[1]}`);
if (rt.nbad > 0 || nCorpus < 1000 || rt.chips === 0) fail('round trip');

// 2. A chip is deleted whole and cannot be typed into.
await evaluate(`(() => { const ta = document.getElementById('ta'); ta.value = 'Hi{pause}x{{y}}'; VPRich.setup(); })()`);
const caretAfter = async (nodeExpr) => evaluate(`(() => {
  const n = ${nodeExpr}; const el = document.getElementById('ed'); el.focus();
  const r = document.createRange(); r.setStartAfter(n); r.collapse(true);
  const s = getSelection(); s.removeAllRanges(); s.addRange(r); return true; })()`);
await caretAfter(`document.querySelector('#ed .chip')`);
await key('Backspace', 'Backspace', 8);
const afterBs = await evaluate(`document.getElementById('ta').value`);
console.log(`backspace after the chip: ${JSON.stringify(afterBs)}`);
if (afterBs !== 'Hix{{y}}') fail('backspace did not remove the chip whole');
await evaluate(`(() => { document.getElementById('ta').value = 'Hi{spd 2}x'; VPRich.render(document.getElementById('ed'), 'Hi{spd 2}x'); })()`);
// Caret placed inside the chip's own text, then a letter typed.
await evaluate(`(() => { const c = document.querySelector('#ed .chip'); document.getElementById('ed').focus();
  const r = document.createRange(); r.setStart(c.firstChild, 1); r.collapse(true);
  const s = getSelection(); s.removeAllRanges(); s.addRange(r); })()`);
await key('Z', 'KeyZ', 90, 'Z');
await send('Input.insertText', { text: 'Q' });
const typed = await evaluate(`(() => [document.querySelector('#ed .chip')?.getAttribute('data-tag'), document.querySelector('#ed .chip')?.textContent, document.getElementById('ta').value])()`);
console.log(`typing on a chip: tag ${typed[0]}, label ${JSON.stringify(typed[1])}, text ${JSON.stringify(typed[2])}`);
if (typed[0] !== '{spd 2}' || typed[1] !== 'spd 2' || !/\{spd 2\}/.test(typed[2])) fail('typing changed a chip');
// Enter inserts a newline the text form keeps.
await caretAfter(`document.querySelector('#ed .chip')`);
await key('Enter', 'Enter', 13, '\r');
const entered = await evaluate(`document.getElementById('ta').value`);
console.log(`enter after the chip: ${JSON.stringify(entered)}`);
if (!/\{spd 2\}\n/.test(entered)) fail('enter did not insert a newline');

// 3. Spellcheck: type the words so the checker sees an edit.
const words = 'Je dois me dépêcher maintenent ';
async function typeInto(id) {
  await evaluate(`(() => { const el = document.getElementById('${id}'); el.textContent = ''; el.focus(); })()`);
  await send('Input.insertText', { text: words });
}
await typeInto('sp0');
await typeInto('sp');
let measured = null;
for (let i = 0; i < 40 && measured === null; i++) {
  await sleep(500);
  const rects = await evaluate(`(() => {
    const out = {};
    for (const id of ['sp', 'sp0']) {
      const el = document.getElementById(id); const t = el.firstChild;
      const k = t.data.indexOf('maintenent'); const g = t.data.indexOf('dépêcher');
      const box = (a, b) => { const r = document.createRange(); r.setStart(t, a); r.setEnd(t, b); const q = r.getBoundingClientRect(); return [q.left, q.top, q.width, q.height]; };
      out[id] = { bad: box(k, k + 10), good: box(g, g + 8) };
    }
    out.dpr = devicePixelRatio; return out; })()`);
  const shot = await send('Page.captureScreenshot', { format: 'png' });
  const png = Buffer.from(shot.data, 'base64');
  const img = decodePng(png);
  const redUnder = (r) => countRed(img, r, rects.dpr);
  const res = { on: redUnder(rects.sp.bad), off: redUnder(rects.sp0.bad), good: redUnder(rects.sp.good) };
  if (res.on > 0 || i === 39) {
    measured = res;
    if (shots) { mkdirSync(shots, { recursive: true }); writeFileSync(join(shots, 'spellcheck.png'), png); }
  }
}
console.log(`spellcheck red pixels under "maintenent": spellcheck on ${measured.on}, off ${measured.off}; under "dépêcher" ${measured.good}`);
let spell = 'NOT MEASURABLE';
if (measured.on > 0 && measured.off === 0 && measured.good === 0) spell = 'PASS';
else if (measured.on > 0) { spell = 'FAIL'; fail('spellcheck marks the wrong words'); }
console.log('spellcheck: ' + spell + (spell === 'NOT MEASURABLE' ? ' (no marker drawn; the French dictionary may not have loaded)' : ''));

ws.close();
chrome.kill();
console.log(failures === 0 ? 'WEB PASS' : `WEB FAIL: ${failures} failures`);
process.exit(failures === 0 ? 0 : 1);

// Minimal PNG reader for Chromium's 8-bit RGB/RGBA screenshots.
function decodePng(buf) {
  let pos = 8, w, h, ct, idat = [];
  while (pos < buf.length) {
    const len = buf.readUInt32BE(pos), type = buf.toString('ascii', pos + 4, pos + 8);
    const data = buf.subarray(pos + 8, pos + 8 + len);
    if (type === 'IHDR') { w = data.readUInt32BE(0); h = data.readUInt32BE(4); ct = data[9]; }
    if (type === 'IDAT') idat.push(data);
    pos += 12 + len;
  }
  const bpp = ct === 6 ? 4 : 3, raw = inflateSync(Buffer.concat(idat)), stride = w * bpp;
  const out = Buffer.alloc(h * stride);
  for (let y = 0; y < h; y++) {
    const f = raw[y * (stride + 1)];
    for (let x = 0; x < stride; x++) {
      const v = raw[y * (stride + 1) + 1 + x];
      const a = x >= bpp ? out[y * stride + x - bpp] : 0, b = y > 0 ? out[(y - 1) * stride + x] : 0;
      const c = x >= bpp && y > 0 ? out[(y - 1) * stride + x - bpp] : 0;
      let p = v;
      if (f === 1) p = v + a; else if (f === 2) p = v + b; else if (f === 3) p = v + ((a + b) >> 1);
      else if (f === 4) { const q = a + b - c, pa = Math.abs(q - a), pb = Math.abs(q - b), pc = Math.abs(q - c); p = v + (pa <= pb && pa <= pc ? a : pb <= pc ? b : c); }
      out[y * stride + x] = p & 255;
    }
  }
  return { w, h, bpp, px: out };
}

// Red pixels in the band just below a text rectangle (where the squiggle is).
function countRed(img, [l, t, wd, ht], dpr) {
  let n = 0;
  for (let y = Math.floor((t + ht * 0.7) * dpr); y < Math.ceil((t + ht + 4) * dpr) && y < img.h; y++) {
    for (let x = Math.floor(l * dpr); x < Math.ceil((l + wd) * dpr) && x < img.w; x++) {
      const i = y * img.w * img.bpp + x * img.bpp, r = img.px[i], g = img.px[i + 1], b = img.px[i + 2];
      if (r > 150 && g < 100 && b < 100) n++;
    }
  }
  return n;
}

#!/usr/bin/env node
// Voice input E2E — headless Chrome + Go backend + fakecore + fake ASR.
//
// Flow:
//   1. build fakecore + Go server (fresh HOME), start both + a fake
//      OpenAI-compatible /audio/transcriptions endpoint
//   2. Chrome → New Session (Simple)
//   3. system menu → ASR config → set the fake endpoint URL → Save
//   4. type "hello world" into the input, move the caret to position 5
//   5. mic start (recording state, input locked) → stop → the mic
//      becomes a cancel while transcribing (input still locked)
//   6. the fake ASR returns "HELLO" → it must be inserted at the caret:
//      "helloHELLO world" and the caret placed after the insert, then
//      the input unlocks
//   7. cancel scenario: slow ASR response → click the mic cancel → the
//      input unlocks and the late result is dropped (no insert, no error)
//   8. raw audio: type text, record with the raw button (input/send/ASR
//      locked) → stop → the WAV data URI is sent as a UA frame with the
//      text; fakecore echoes it back as an audio chip
//
// ALL PASS printed on success. Screenshots land in the artifact dir.
import puppeteer from 'puppeteer-core';
import { execSync, spawn } from 'node:child_process';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import net from 'node:net';
import http from 'node:http';

const ROOT = path.resolve(import.meta.dirname, '..');
const CHROME = '/usr/bin/google-chrome';

function assert(cond, msg) {
  if (!cond) throw new Error('ASSERT FAILED: ' + msg);
}

function freePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.listen(0, '127.0.0.1', () => {
      const port = srv.address().port;
      srv.close(() => resolve(port));
    });
    srv.on('error', reject);
  });
}
function waitPort(port, ms) {
  const deadline = Date.now() + ms;
  return new Promise((resolve, reject) => {
    const tick = () => {
      const sock = net.connect(port, '127.0.0.1');
      sock.on('connect', () => { sock.destroy(); resolve(); });
      sock.on('error', () => {
        sock.destroy();
        if (Date.now() > deadline) reject(new Error('port timeout'));
        else setTimeout(tick, 250);
      });
    };
    tick();
  });
}

const tmp = mkdtempSync(path.join(tmpdir(), 'alayaface-voice-e2e-'));
const home = path.join(tmp, 'home');
const artifacts = path.join(tmp, 'shots');
const SRCGO = path.join(ROOT, 'src-go');
execSync(`mkdir -p "${artifacts}" "${home}"`);
console.log('artifacts:', tmp);

const fakecore = path.join(tmp, 'fakecore');
const serverBin = path.join(tmp, 'alayaface-server');
execSync('go build -o "' + fakecore + '" ./internal/fakecore', { cwd: SRCGO, stdio: 'inherit' });
execSync('go build -o "' + serverBin + '" ./cmd/alayaface-server', { cwd: SRCGO, stdio: 'inherit' });

// ── fake ASR endpoint: OpenAI-compatible /v1/audio/transcriptions ──
// Records how many calls it got and answers {"text":"HELLO"}. When
// asrSlow is set (the cancel scenario) it delays the response so the
// test can cancel the transcription mid-flight.
let asrCalls = 0;
let asrSlow = false;
const asrServer = http.createServer((req, res) => {
  if (req.url === '/v1/audio/transcriptions' && req.method === 'POST') {
    asrCalls++;
    const chunks = [];
    req.on('data', c => chunks.push(c));
    req.on('end', () => {
      const respond = () => {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ text: 'HELLO' }));
      };
      if (asrSlow) setTimeout(respond, 4000);
      else respond();
    });
    return;
  }
  res.writeHead(404).end();
});
await new Promise(r => asrServer.listen(0, '127.0.0.1', r));
const asrPort = asrServer.address().port;

const port = await freePort();
const base = `http://127.0.0.1:${port}`;
const server = spawn(serverBin, ['--addr', `127.0.0.1:${port}`, '--static', '../src-elm', '--alayacore-bin', fakecore], {
  cwd: SRCGO,
  env: { ...process.env, HOME: home },
  stdio: ['ignore', 'pipe', 'pipe'],
});
server.stdout.on('data', d => process.stdout.write('[srv] ' + d));
server.stderr.on('data', d => process.stdout.write('[srv!] ' + d));

function killAll() {
  try { server.kill('SIGTERM'); } catch {}
  try { asrServer.close(); } catch {}
  try { rmSync(tmp, { recursive: true, force: true }); } catch {}
}

try {
  await waitPort(port, 30000);
  const browser = await puppeteer.launch({
    executablePath: CHROME,
    headless: true,
    args: [
      '--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu',
      '--window-size=1440,920',
      '--use-fake-ui-for-media-stream',
      '--use-fake-device-for-media-stream',
      '--autoplay-policy=no-user-gesture-required',
    ],
  });
  const page = await browser.newPage();
  await page.setViewport({ width: 1440, height: 920 });
  page.on('pageerror', e => console.log('[pageerror]', e.message));
  page.on('console', m => {
    console.log('[console.' + m.type() + ']', m.text());
  });

  const waitFor = (sel, ms = 30000) => page.waitForSelector(sel, { timeout: ms, visible: true });
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const shot = name => page.screenshot({ path: path.join(artifacts, name) });
  const openGlobalMenu = async () => {
    await page.$eval('.main-content', el => el.dispatchEvent(
      new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 30, clientY: 30 })));
    await waitFor('.global-menu-panel');
  };
  const clickMenuItem = async (label) => {
    const items = await page.$$('.global-menu-item');
    for (const h of items) {
      if ((await h.evaluate(el => el.textContent || '')).includes(label)) { await h.click(); return true; }
    }
    return false;
  };

  // ── 2. session ───────────────────────────────────────────────────
  await page.goto(base + '/', { waitUntil: 'networkidle0', timeout: 30000 });
  await page.waitForSelector('.main-content', { timeout: 30000 });
  await openGlobalMenu();
  assert(await clickMenuItem('New Session'), 'menu: New Session');
  await sleep(200);
  const subs = await page.$$('.global-menu-submenu-item');
  let created = false;
  for (const s of subs) {
    if ((await s.evaluate(el => el.textContent || '')).includes('Simple')) { await s.click(); created = true; break; }
  }
  assert(created, 'preset submenu: Simple');
  await waitFor('.session-panel');
  await sleep(800);

  // ── 3. ASR config overlay: add a profile via the list → form ─────
  await openGlobalMenu();
  assert(await clickMenuItem('ASR config'), 'menu: ASR config');
  await waitFor('.me-page');
  // Wait for the list (loading finishes) before clicking Add.
  await page.waitForSelector('.me-save-btn', { timeout: 10000 });
  await shot('01-asr-list-empty.png');
  // Empty list → Add endpoint enters the form.
  await page.$eval('.me-save-btn', el => el.click());
  await waitFor('#asr-config-url');
  await sleep(200);
  await page.$eval('#asr-config-name', (el, v) => { el.value = v; el.dispatchEvent(new Event('input', { bubbles: true })); }, 'Local whisper');
  await page.$eval('#asr-config-url', (el, url) => { el.value = url; el.dispatchEvent(new Event('input', { bubbles: true })); }, `http://127.0.0.1:${asrPort}/v1/audio/transcriptions`);
  await sleep(200);
  await page.$eval('.me-save-btn', el => el.click());
  await sleep(800);
  // Back on the list; the new profile is active (first one).
  const rowCount = await page.$$eval('.asr-row', els => els.length);
  assert(rowCount === 1, 'profile list shows one row, got ' + rowCount);
  const rowMeta = await page.$eval('.asr-row-meta', el => el.textContent || '');
  assert(rowMeta.includes('/audio/transcriptions'), 'row shows the URL: ' + rowMeta);
  const activeBadge = await page.$('.asr-row-active');
  assert(!!activeBadge, 'first profile is marked active');
  await shot('02-asr-list-one.png');
  // Close the overlay.
  await page.$eval('.overlay-close', el => el.click());
  await sleep(300);
  assert(await page.$('.me-page') === null, 'ASR overlay closed');
  console.log('ASR profile added');

  // ── 4. caret position ────────────────────────────────────────────
  const taSel = 'textarea.input-text';
  await page.type(taSel, 'hello world');
  await sleep(200);
  await page.$eval(taSel, el => { el.focus(); el.setSelectionRange(5, 5); });
  await sleep(100);
  const before = await page.$eval(taSel, el => ({ v: el.value, sel: el.selectionStart }));
  assert(before.v === 'hello world' && before.sel === 5, 'input prepared: ' + JSON.stringify(before));

  // ── 5. record → stop → transcribe ────────────────────────────────
  const micState = () => page.evaluate(() => {
    const btn = document.querySelector('.mic-btn');
    return {
      cls: btn ? btn.className : '',
      disabled: btn ? btn.disabled : null,
    };
  });
  const taState = () => page.$eval(taSel, el => ({ disabled: el.disabled, v: el.value }));
  // Slow ASR response so the transcribing state is observable.
  asrSlow = true;
  await page.$eval('.mic-btn', el => el.click());
  await sleep(1500);
  const rec = await micState();
  assert(rec.cls.includes('recording'), 'mic enters recording state: ' + rec.cls);
  assert(rec.disabled === false, 'mic stays clickable while recording (to stop)');
  assert((await taState()).disabled === true, 'input disabled while recording');
  await shot('02-recording.png');

  await page.$eval('.mic-btn', el => el.click());
  await sleep(400);
  // Transcribing: input stays locked, mic becomes a cancel button.
  const busy = await micState();
  assert(busy.cls.includes('cancel'), 'mic becomes cancel while transcribing: ' + busy.cls);
  assert(busy.cls.includes('recording') === false, 'recording pulse cleared while transcribing');
  assert(busy.disabled === false, 'mic cancel stays clickable');
  assert((await taState()).disabled === true, 'input stays disabled while transcribing');
  await shot('02b-transcribing.png');

  // ── 6. insertion at the caret ────────────────────────────────────
  await sleep(4200); // slow response arrives (~4s after the POST)
  const after = await page.$eval(taSel, el => ({ v: el.value, sel: el.selectionStart }));
  console.log('after insert:', JSON.stringify(after));
  assert(after.v === 'helloHELLO world', 'inserted at caret: ' + after.v);
  assert(after.sel === 10, 'caret after inserted text: ' + after.sel);
  assert((await taState()).disabled === false, 'input re-enabled after insertion');
  assert(asrCalls >= 1, 'fake ASR endpoint was called (' + asrCalls + ')');
  await shot('03-inserted.png');

  // ── 7. cancel mid-transcription discards the result ──────────────
  asrSlow = true;
  await page.$eval(taSel, el => { el.focus(); el.setSelectionRange(0, 0); });
  await page.$eval('.mic-btn', el => el.click());
  await sleep(1200);
  assert((await taState()).disabled === true, 'input disabled while recording (cancel scenario)');
  await page.$eval('.mic-btn', el => el.click());
  await sleep(400);
  const busy2 = await micState();
  assert(busy2.cls.includes('cancel'), 'mic is cancel while transcribing (cancel scenario): ' + busy2.cls);
  // Click the cancel button: the pending result must be abandoned.
  await page.$eval('.mic-btn', el => el.click());
  await sleep(400);
  const afterCancel = await micState();
  assert(!afterCancel.cls.includes('recording') && !afterCancel.cls.includes('cancel'),
    'mic back to normal after cancel: ' + afterCancel.cls);
  assert((await taState()).disabled === false, 'input re-enabled after cancel');
  // The slow ASR response arrives later and must be dropped silently.
  await sleep(4600);
  const finalState = await page.$eval(taSel, el => ({ v: el.value, disabled: el.disabled }));
  assert(finalState.v === 'helloHELLO world', 'cancelled transcript NOT inserted: ' + finalState.v);
  assert(finalState.disabled === false, 'input stays enabled after dropped result');
  const errorCount = await page.$$eval('.message-error', els => els.length);
  assert(errorCount === 0, 'no error message from the dropped result');
  const finalMic = await micState();
  assert(!finalMic.cls.includes('cancel') && !finalMic.cls.includes('recording'),
    'mic idle after dropped result: ' + finalMic.cls);
  asrSlow = false;
  await shot('04-cancelled.png');

  // ── 8. raw audio → UA frame ─────────────────────────────────────
  // Type some text, record raw audio (input/send/ASR locked), stop →
  // the WAV data URI is sent as a UA frame together with the text;
  // fakecore echoes it back and the session shows an audio chip.
  const btnState = (sel) => page.evaluate((s) => {
    const btn = document.querySelector(s);
    return { cls: btn ? btn.className : '', disabled: btn ? btn.disabled : null };
  }, sel);
  await page.type(taSel, 'describe this audio');
  await sleep(200);
  await page.$eval('.raw-btn', el => el.click());
  await sleep(1200);
  const rawRec = await btnState('.raw-btn');
  assert(rawRec.cls.includes('recording'), 'raw button enters recording state: ' + rawRec.cls);
  assert(rawRec.disabled === false, 'raw button stays clickable while recording (to stop)');
  assert((await taState()).disabled === true, 'input disabled while raw recording');
  assert((await btnState('.send-btn')).disabled === true, 'send disabled while raw recording');
  assert((await btnState('.mic-btn')).disabled === true, 'ASR mic disabled while raw recording');
  await shot('05-raw-recording.png');

  await page.$eval('.raw-btn', el => el.click());
  await sleep(3000); // encode → send_prompt → UA echo → message render
  const rawDone = await btnState('.raw-btn');
  assert(!rawDone.cls.includes('recording'), 'raw button back to normal: ' + rawDone.cls);
  assert((await taState()).disabled === false, 'input re-enabled after raw send');
  const afterRaw = await page.$eval(taSel, el => ({ v: el.value }));
  assert(afterRaw.v === '', 'input cleared after raw send: ' + afterRaw.v);
  const audioChip = await page.$('.message-media-chip');
  assert(!!audioChip, 'UA echo rendered an audio chip');
  const bodyText = await page.evaluate(() => document.body.textContent || '');
  assert(bodyText.includes('describe this audio'), 'typed text went along with the audio');
  await shot('06-raw-sent.png');

  await browser.close();
  killAll();
  console.log('ALL PASS');
} catch (e) {
  killAll();
  console.error('FAIL:', e.message);
  process.exit(1);
}

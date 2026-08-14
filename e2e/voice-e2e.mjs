#!/usr/bin/env node
// Voice input E2E — headless Chrome + Go backend + fakecore + fake ASR.
//
// Flow:
//   1. build fakecore + Go server (fresh HOME), start both + a fake
//      OpenAI-compatible /audio/transcriptions endpoint
//   2. Chrome → New Session (Simple)
//   3. system menu → ASR config → set the fake endpoint URL → Save
//   4. type "hello world" into the input, move the caret to position 5
//   5. mic start (recording state, "Listening…" in the bar) → stop
//   6. the fake ASR returns "HELLO" → it must be inserted at the caret:
//      "helloHELLO world" and the caret placed after the insert
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
// Records how many calls it got and answers {"text":"HELLO"}.
let asrCalls = 0;
const asrServer = http.createServer((req, res) => {
  if (req.url === '/v1/audio/transcriptions' && req.method === 'POST') {
    asrCalls++;
    const chunks = [];
    req.on('data', c => chunks.push(c));
    req.on('end', () => {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ text: 'HELLO' }));
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

  // ── 3. ASR config overlay ────────────────────────────────────────
  await openGlobalMenu();
  assert(await clickMenuItem('ASR config'), 'menu: ASR config');
  await waitFor('.me-page');
  await sleep(300);
  await shot('01-asr-config.png');
  await page.$eval('#asr-config-url', (el, url) => { el.value = url; el.dispatchEvent(new Event('input', { bubbles: true })); }, `http://127.0.0.1:${asrPort}/v1/audio/transcriptions`);
  await sleep(200);
  await page.$eval('.me-save-btn', el => el.click());
  await sleep(800);
  const overlayGone = await page.$('.me-page') === null;
  assert(overlayGone, 'ASR config overlay closed after save');
  console.log('ASR config saved');

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
  await page.$eval('.mic-btn', el => el.click());
  await sleep(1500);
  const rec = await micState();
  assert(rec.cls.includes('recording'), 'mic enters recording state: ' + rec.cls);
  await shot('02-recording.png');

  await page.$eval('.mic-btn', el => el.click());
  await sleep(3500);
  const done = await micState();
  console.log('after stop:', JSON.stringify(done));

  // ── 6. insertion at the caret ────────────────────────────────────
  const after = await page.$eval(taSel, el => ({ v: el.value, sel: el.selectionStart }));
  console.log('after insert:', JSON.stringify(after));
  assert(after.v === 'helloHELLO world', 'inserted at caret: ' + after.v);
  assert(after.sel === 10, 'caret after inserted text: ' + after.sel);
  assert(asrCalls >= 1, 'fake ASR endpoint was called (' + asrCalls + ')');
  await shot('03-inserted.png');

  await browser.close();
  killAll();
  console.log('ALL PASS');
} catch (e) {
  killAll();
  console.error('FAIL:', e.message);
  process.exit(1);
}

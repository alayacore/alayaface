#!/usr/bin/env node
// Push-to-talk E2E — headless Chrome + Go backend + fakecore + fake ASR.
//
// Flow:
//   1. build fakecore + Go server (fresh HOME), start both + a fake
//      OpenAI-compatible /audio/transcriptions endpoint
//   2. Chrome → ASR config → set the fake endpoint URL → Save
//   3. WITHOUT creating any session via the UI: hold Shift+` → a NEW
//      session appears under the built-in "Talk" preset and ASR
//      recording starts (mic button pulses red); the global preset
//      menu also lists "Talk"
//   4. release → transcription inserted into the prompt input, and the
//      input IS focused (Enter sends right away)
//   5. hold Shift+` again → a SECOND session appears and records →
//      release → second transcript inserted
//   6. plain ` (no Shift) records in the CURRENT session: NO new
//      session is created, the active session transcribes
//
// ALL PASS printed on success. Screenshots land in the artifact dir.
import puppeteer from 'puppeteer-core';
import { execSync, spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
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

const tmp = mkdtempSync(path.join(tmpdir(), 'alayaface-pt-e2e-'));
const home = path.join(tmp, 'home');
const artifacts = path.join(tmp, 'shots');
const SRCGO = path.join(ROOT, 'src-go');
execSync(`mkdir -p "${artifacts}" "${home}"`);
console.log('artifacts:', tmp);

const fakecore = path.join(tmp, 'fakecore');
const serverBin = path.join(tmp, 'alayaface-server');
execSync('go build -o "' + fakecore + '" ./internal/fakecore', { cwd: SRCGO, stdio: 'inherit' });
execSync('go build -o "' + serverBin + '" ./cmd/alayaface-server', { cwd: SRCGO, stdio: 'inherit' });

// ── fake ASR endpoint ──────────────────────────────────────────────
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

  await page.goto(base + '/', { waitUntil: 'networkidle0', timeout: 30000 });
  await page.waitForSelector('.main-content', { timeout: 30000 });

  // ── ASR config overlay: add the fake endpoint profile ────────────
  await openGlobalMenu();
  assert(await clickMenuItem('ASR config'), 'menu: ASR config');
  await waitFor('.me-page');
  await page.waitForSelector('.me-save-btn', { timeout: 10000 });
  await page.$eval('.me-save-btn', el => el.click());
  await waitFor('#asr-config-url');
  await sleep(200);
  await page.$eval('#asr-config-name', (el, v) => { el.value = v; el.dispatchEvent(new Event('input', { bubbles: true })); }, 'Local whisper');
  await page.$eval('#asr-config-url', (el, url) => { el.value = url; el.dispatchEvent(new Event('input', { bubbles: true })); }, `http://127.0.0.1:${asrPort}/v1/audio/transcriptions`);
  await sleep(200);
  await page.$eval('.me-save-btn', el => el.click());
  await sleep(800);
  const rowCount = await page.$$eval('.asr-row', els => els.length);
  assert(rowCount === 1, 'profile list shows one row, got ' + rowCount);
  await page.$eval('.overlay-close', el => el.click());
  await sleep(300);
  console.log('ASR profile added');

  // ── Talk preset must be seeded and listed in the global menu ─────
  await openGlobalMenu();
  assert(await clickMenuItem('New Session'), 'menu: New Session');
  await sleep(200);
  const subs = await page.$$('.global-menu-submenu-item');
  const labels = [];
  for (const s of subs) labels.push(await s.evaluate(el => el.textContent || ''));
  assert(labels.some(l => l.includes('Talk')), 'preset submenu lists Talk: ' + JSON.stringify(labels));
  // Close the menu without creating a session (the PT key must be the
  // one that creates sessions).
  await page.keyboard.press('Escape');
  await sleep(200);
  assert(await page.$('.session-panel') === null, 'no session before PT');
  console.log('Talk preset seeded; no session yet');

  // ── PT round 1: hold Shift+` → new Talk session + recording ─────
  await page.keyboard.down('Shift');
  await page.keyboard.down('`');
  await waitFor('.mic-btn.recording', 15000);
  await sleep(500);
  let panels = await page.$$('.session-panel');
  assert(panels.length === 1, 'Shift+` created exactly one session, got ' + panels.length);
  const recState = await page.evaluate(() => {
    const btn = document.querySelector('.mic-btn');
    return { cls: btn ? btn.className : '', disabled: btn ? btn.disabled : null };
  });
  assert(recState.cls.includes('recording'), 'mic recording state: ' + recState.cls);
  assert(recState.disabled === false, 'mic clickable while recording (to stop)');
  const locked = await page.$eval('textarea.input-text', el => el.disabled);
  assert(locked === true, 'input locked while PT recording');
  await shot('01-pt-recording.png');
  console.log('PT round 1 recording (Shift+`)');

  // ── release → transcribe → insert WITH the input focused ────────
  await page.keyboard.up('`');
  await page.keyboard.up('Shift');
  // Wait until the transcript lands in the input (ASR is instant here).
  let inserted = false;
  for (let i = 0; i < 40; i++) {
    const v = await page.$eval('textarea.input-text', el => el.value);
    if (v.includes('HELLO')) { inserted = true; break; }
    await sleep(250);
  }
  assert(inserted, 'transcript inserted into the input');
  const taState = await page.$eval('textarea.input-text', el => ({ v: el.value, disabled: el.disabled }));
  assert(taState.v.includes('HELLO'), 'input contains the transcript: ' + taState.v);
  assert(taState.disabled === false, 'input unlocked after insertion');
  // The input must be FOCUSED after the insert so Enter sends right
  // away (the user asked for this over the unfocused talk-loop).
  await sleep(800); // setCursorPos applies focus on a deferred timer
  const activeEl = await page.evaluate(() => document.activeElement ? document.activeElement.tagName : 'none');
  assert(activeEl === 'TEXTAREA', 'input focused after PT insert (active=' + activeEl + ')');
  assert(asrCalls >= 1, 'fake ASR endpoint was called (' + asrCalls + ')');
  await shot('02-pt-inserted.png');
  console.log('PT round 1 transcript inserted, input focused');

  // ── PT round 2: Shift+` again → a SECOND new session ────────────
  // The input now holds focus (Enter-to-send convenience), so the talk
  // key needs the focus OUT of the textarea — the user clicks the
  // canvas/blank space, exactly like Discord's push-to-talk.
  await page.$eval('textarea.input-text', el => el.blur());
  await sleep(100);
  await page.keyboard.down('Shift');
  await page.keyboard.down('`');
  await waitFor('.mic-btn.recording', 15000);
  await sleep(500);
  panels = await page.$$('.session-panel');
  assert(panels.length === 2, 'Shift+` round 2 created a second session, got ' + panels.length);
  await shot('03-pt-round2-recording.png');
  await page.keyboard.up('`');
  await page.keyboard.up('Shift');
  inserted = false;
  for (let i = 0; i < 40; i++) {
    // The focused session's textarea is the LAST one in DOM order; wait
    // for round-2's HELLO there AND for the input to unlock (the
    // transcription was consumed). The first session's textarea already
    // holds round-1's HELLO, so checking the first element would
    // false-positive.
    const vals = await page.$$eval('textarea.input-text',
      els => els.map(e => ({ v: e.value, d: e.disabled })));
    const fresh = vals[vals.length - 1];
    if (fresh && fresh.v.includes('HELLO') && !fresh.d) { inserted = true; break; }
    await sleep(250);
  }
  if (!inserted) {
    // Diagnose: dump every input, error message and mic state.
    const diag = await page.evaluate(() => {
      const errs = Array.from(document.querySelectorAll('.message-error')).map(e => e.textContent || '');
      const ta = document.querySelectorAll('textarea.input-text');
      const mic = document.querySelector('.mic-btn');
      return {
        errs,
        inputs: Array.from(ta).map(t => ({ v: t.value, disabled: t.disabled })),
        mic: mic ? mic.className : 'none',
        active: document.activeElement ? document.activeElement.tagName : 'none',
      };
    });
    console.log('ROUND2 STATE:', JSON.stringify(diag));
  }
  assert(inserted, 'round 2 transcript inserted');
  assert(asrCalls >= 2, 'fake ASR called twice (' + asrCalls + ')');
  await shot('04-pt-round2-inserted.png');
  console.log('PT round 2 transcript inserted');

  // ── PT round 3: plain ` records in the CURRENT session ──────────
  // No new session — the active (focused) one records and transcribes.
  const panelsBefore3 = await page.$$('.session-panel');
  assert(panelsBefore3.length === 2, 'two sessions before plain-` talk');
  await page.evaluate(() => document.activeElement && document.activeElement.blur());
  await sleep(100);
  await page.keyboard.down('`');
  await waitFor('.mic-btn.recording', 15000);
  await sleep(500);
  const panels3 = await page.$$('.session-panel');
  assert(panels3.length === 2, 'plain ` must NOT create a session (got ' + panels3.length + ')');
  await shot('05-pt-plain-recording.png');
  await page.keyboard.up('`');
  inserted = false;
  for (let i = 0; i < 40; i++) {
    const vals = await page.$$eval('textarea.input-text',
      els => els.map(e => ({ v: e.value, d: e.disabled })));
    const fresh = vals[vals.length - 1];
    if (fresh && fresh.v.includes('HELLO') && !fresh.d) { inserted = true; break; }
    await sleep(250);
  }
  assert(inserted, 'plain-` transcript inserted into the CURRENT session');
  assert(asrCalls >= 3, 'fake ASR called three times (' + asrCalls + ')');
  await shot('06-pt-plain-inserted.png');
  console.log('PT round 3 (plain `) transcript inserted, no new session');

  console.log('ALL PASS');
  await browser.close();
  killAll();
  process.exit(0);
} catch (e) {
  console.error('E2E FAILED:', e.message);
  try { await page.screenshot({ path: path.join(artifacts, 'failure.png') }); } catch {}
  killAll();
  process.exit(1);
}

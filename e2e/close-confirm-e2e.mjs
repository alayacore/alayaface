#!/usr/bin/env node
// Close-session confirmation E2E — headless Chrome + Go backend +
// fakecore.
//
// Flow:
//   1. build fakecore + Go server (fresh HOME), start both
//   2. create a session via the global menu (Simple preset)
//   3. click the window ✕ → a confirm overlay appears with Close /
//      Close and Delete / Cancel; the session is still open
//   4. Cancel → overlay closes, session stays
//   5. ✕ again → "Close and Delete" → session window gone
//   6. create another session → ✕ → press Enter (Close is the
//      autofocused default) → session closes, conversation kept
//
// ALL PASS printed on success. Screenshots land in the artifact dir.
import puppeteer from 'puppeteer-core';
import { execSync, spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import net from 'node:net';

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

const tmp = mkdtempSync(path.join(tmpdir(), 'alayaface-closeconf-e2e-'));
const home = path.join(tmp, 'home');
const artifacts = path.join(tmp, 'shots');
const SRCGO = path.join(ROOT, 'src-go');
execSync(`mkdir -p "${artifacts}" "${home}"`);
console.log('artifacts:', tmp);

const fakecore = path.join(tmp, 'fakecore');
const serverBin = path.join(tmp, 'alayaface-server');
execSync('go build -o "' + fakecore + '" ./internal/fakecore', { cwd: SRCGO, stdio: 'inherit' });
execSync('go build -o "' + serverBin + '" ./cmd/alayaface-server', { cwd: SRCGO, stdio: 'inherit' });

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
  try { rmSync(tmp, { recursive: true, force: true }); } catch {}
}

try {
  await waitPort(port, 30000);
  const browser = await puppeteer.launch({
    executablePath: CHROME,
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu', '--window-size=1440,920'],
  });
  const page = await browser.newPage();
  await page.setViewport({ width: 1440, height: 920 });
  page.on('pageerror', e => console.log('[pageerror]', e.message));
  page.on('console', m => console.log('[console.' + m.type() + ']', m.text()));

  const waitFor = (sel, ms = 30000) => page.waitForSelector(sel, { timeout: ms, visible: true });
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const shot = name => page.screenshot({ path: path.join(artifacts, name) });
  const openGlobalMenu = async () => {
    await page.$eval('.main-content', el => el.dispatchEvent(
      new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 30, clientY: 30 })));
    await waitFor('.global-menu-panel');
  };
  const createSession = async () => {
    await openGlobalMenu();
    const items = await page.$$('.global-menu-item');
    for (const h of items) {
      if ((await h.evaluate(el => el.textContent || '')).includes('New Session')) { await h.click(); break; }
    }
    await sleep(200);
    const subs = await page.$$('.global-menu-submenu-item');
    let created = false;
    for (const s of subs) {
      if ((await s.evaluate(el => el.textContent || '')).includes('Simple')) { await s.click(); created = true; break; }
    }
    assert(created, 'preset submenu: Simple');
    await waitFor('.session-panel');
    await sleep(600);
  };
  const overlayButtons = () => page.$$eval('.overlay .confirm-page-buttons button', els => els.map(e => e.textContent || ''));

  await page.goto(base + '/', { waitUntil: 'networkidle0', timeout: 30000 });
  await page.waitForSelector('.main-content', { timeout: 30000 });

  // ── 2. create a session ──────────────────────────────────────────
  await createSession();
  assert(await page.$('.session-panel') !== null, 'session created');

  // ── 3. ✕ → confirm overlay; session still open ───────────────────
  await page.$eval('.session-bar-close', el => el.click());
  await waitFor('.overlay .confirm-page-title');
  await sleep(200);
  const inPanel = await page.$eval('.overlay', el => !!el.closest('.session-panel'));
  assert(inPanel, 'confirm overlay renders INSIDE the session panel (per-session)');
  const btns = await overlayButtons();
  assert(btns.length === 3, 'three buttons, got ' + JSON.stringify(btns));
  assert(btns[0].includes('Close'), 'button 1 is Close: ' + JSON.stringify(btns));
  assert(btns[1].includes('Close and Delete'), 'button 2 is Close and Delete: ' + JSON.stringify(btns));
  assert(btns[2].includes('Cancel'), 'button 3 is Cancel: ' + JSON.stringify(btns));
  const title = await page.$eval('.overlay .confirm-page-title', el => el.textContent || '');
  assert(title.includes('Close session'), 'title: ' + title);
  const activeTag = await page.evaluate(() => document.activeElement ? document.activeElement.tagName : 'none');
  const activeText = await page.evaluate(() => document.activeElement ? (document.activeElement.textContent || '') : '');
  assert(activeTag === 'BUTTON' && activeText.includes('Close'), 'Close is autofocused (default): ' + activeTag + ' / ' + activeText);
  assert(await page.$('.session-panel') !== null, 'session still open while confirming');
  await shot('01-confirm-open.png');

  // ── 4. Cancel keeps the session ──────────────────────────────────
  const cancelBtn = await page.$$('.overlay .confirm-page-buttons button');
  await cancelBtn[2].click();
  await sleep(300);
  assert(await page.$('.overlay .confirm-page-title') === null, 'overlay closed after Cancel');
  assert(await page.$('.session-panel') !== null, 'session stays after Cancel');
  await shot('02-after-cancel.png');

  // ── 5. ✕ → Close and Delete removes the session ──────────────────
  await page.$eval('.session-bar-close', el => el.click());
  await waitFor('.overlay .confirm-page-title');
  await sleep(200);
  const btns2 = await page.$$('.overlay .confirm-page-buttons button');
  await btns2[1].click(); // Close and Delete
  await sleep(600);
  assert(await page.$('.overlay .confirm-page-title') === null, 'overlay closed after Close and Delete');
  assert(await page.$('.session-panel') === null, 'session gone after Close and Delete');
  // On-disk: the session directory under ~/.alayaface/sessions/ must be
  // removed recursively (this e2e created exactly one session).
  const leftover = execSync(
    `find "${home}/.alayaface/sessions" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l`
  ).toString().trim();
  assert(leftover === '0', 'session dir removed from disk, leftover=' + leftover);
  await shot('03-after-delete.png');

  // ── 6. Enter confirms the default (Close) ────────────────────────
  await createSession();
  assert(await page.$('.session-panel') !== null, 'second session created');
  await page.$eval('.session-bar-close', el => el.click());
  await waitFor('.overlay .confirm-page-title');
  await sleep(200);
  await page.keyboard.press('Enter'); // autofocused Close button
  await sleep(600);
  assert(await page.$('.overlay .confirm-page-title') === null, 'overlay closed after Enter');
  assert(await page.$('.session-panel') === null, 'session closed by Enter (default Close)');
  await shot('04-after-enter-close.png');

  // ── 7. Escape cancels ────────────────────────────────────────────
  await createSession();
  await page.$eval('.session-bar-close', el => el.click());
  await waitFor('.overlay .confirm-page-title');
  await sleep(200);
  await page.keyboard.press('Escape');
  await sleep(300);
  assert(await page.$('.overlay .confirm-page-title') === null, 'overlay closed after Escape');
  assert(await page.$('.session-panel') !== null, 'session stays after Escape');
  await shot('05-after-escape.png');

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

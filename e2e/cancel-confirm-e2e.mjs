#!/usr/bin/env node
// Cancel-task confirmation E2E — headless Chrome + Go backend +
// fakecore (hang-once marker makes a task hang until cancelled).
//
// Flow:
//   1. build fakecore + Go server (fresh HOME), start both
//   2. create a session, send a "hang-once" prompt → the task hangs →
//      the send button turns into "Cancel task"
//   3. click the cancel button → a PER-SESSION confirm overlay appears
//      with "Cancel task" / "Keep running"; the task is still running
//   4. "Keep running" → overlay closes, task keeps hanging
//   5. Ctrl+G → the same overlay opens; Enter (default "Cancel task")
//      aborts it → fakecore recovers and the task ends
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

const tmp = mkdtempSync(path.join(tmpdir(), 'alayaface-cancelconf-e2e-'));
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
  const overlayButtons = () => page.$$eval('.overlay .confirm-page-btn', els => els.map(e => e.textContent || ''));

  await page.goto(base + '/', { waitUntil: 'networkidle0', timeout: 30000 });
  await page.waitForSelector('.main-content', { timeout: 30000 });
  await createSession();

  // ── 2. hang the task: send a "hang-once" prompt ──────────────────
  // Unique text per run: fakecore's hang-once marker keys off a hash of
  // the prompt in /tmp, so a repeated text would only hang ONCE across
  // all e2e runs.
  const hangPrompt = 'hang-once please ' + Date.now();
  await page.type('textarea.input-text', hangPrompt);
  await sleep(200);
  await page.keyboard.press('Enter');
  // The send button turns into "Cancel task" while the task hangs.
  await waitFor('.send-btn.cancel', 15000);
  await sleep(400);
  await shot('01-task-hanging.png');
  console.log('task hanging (send button shows Cancel)');

  // ── 3. click the cancel button → per-session confirm overlay ─────
  await page.$eval('.send-btn', el => el.click());
  await waitFor('.overlay .confirm-page-title');
  await sleep(200);
  const title = await page.$eval('.overlay .confirm-page-title', el => el.textContent || '');
  assert(title.includes('Cancel task'), 'title: ' + title);
  const inPanel = await page.$eval('.overlay', el => !!el.closest('.session-panel'));
  assert(inPanel, 'confirm overlay renders INSIDE the session panel (per-session)');
  const btns = await overlayButtons();
  assert(btns.length === 2, 'two buttons, got ' + JSON.stringify(btns));
  assert(btns[0].includes('Cancel task'), 'button 1 is Cancel task: ' + JSON.stringify(btns));
  assert(btns[1].includes('Keep running'), 'button 2 is Keep running: ' + JSON.stringify(btns));
  // Default focus is the "Cancel task" button.
  const activeText = await page.evaluate(() => document.activeElement ? (document.activeElement.textContent || '') : '');
  assert(activeText.includes('Cancel task'), 'Cancel task is the focused default: ' + activeText);
  const stillRunning = await page.$('.send-btn.cancel') !== null;
  assert(stillRunning, 'task still running while confirming');
  await shot('02-cancel-confirm.png');

  // ── 4. Keep running → overlay closes, task keeps hanging ─────────
  const keepBtn = await page.$$('.overlay .confirm-page-btn');
  await keepBtn[1].click();
  await sleep(300);
  assert(await page.$('.overlay .confirm-page-title') === null, 'overlay closed after Keep running');
  assert(await page.$('.send-btn.cancel') !== null, 'task still running after Keep running');
  await shot('03-after-keep.png');

  // ── 5. Ctrl+G opens the same overlay; Enter aborts (default) ─────
  await page.keyboard.down('Control');
  await page.keyboard.press('g');
  await page.keyboard.up('Control');
  await waitFor('.overlay .confirm-page-title');
  await sleep(200);
  await shot('04-ctrl-g-confirm.png');
  await page.keyboard.press('Enter'); // default: Cancel task
  await sleep(400);
  assert(await page.$('.overlay .confirm-page-title') === null, 'overlay closed after Enter');
  // The task was cancelled: fakecore recovers from hang and the send
  // button returns to Send.
  await page.waitForFunction(() => !document.querySelector('.send-btn.cancel'), { timeout: 15000 });
  await sleep(400);
  await shot('05-after-cancel.png');
  console.log('task cancelled, send button back to Send');

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

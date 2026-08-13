#!/usr/bin/env node
// Touch & pointer E2E: CDP touch emulation over the unified pointer
// pipeline — single-finger pan, window drag, two-finger pinch zoom,
// long-press menu (touch right-click), tap-toggle preset submenu and
// session creation, plus a mouse right-click regression check.
//
// Screenshots land in the artifact dir; ALL PASS printed on success.

import puppeteer from 'puppeteer-core';
import { execSync, spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import net from 'node:net';

const ROOT = path.resolve(import.meta.dirname, '..');
const CHROME = '/usr/bin/google-chrome';
const SRCGO = path.join(ROOT, 'src-go');

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
const sleep = ms => new Promise(r => setTimeout(r, ms));

const tmp = mkdtempSync(path.join(tmpdir(), 'touch-e2e-'));
const home = path.join(tmp, 'home');
const shots = path.join(tmp, 'shots');
execSync(`mkdir -p "${home}" "${shots}"`);
const fakecore = path.join(tmp, 'fakecore');
const serverBin = path.join(tmp, 'server');
execSync('go build -o "' + fakecore + '" ./internal/fakecore', { cwd: SRCGO, stdio: 'inherit' });
execSync('go build -o "' + serverBin + '" ./cmd/alayaface-server', { cwd: SRCGO, stdio: 'inherit' });

const port = await freePort();
const srv = spawn(serverBin, ['--addr', `127.0.0.1:${port}`, '--static', '../src-elm', '--alayacore-bin', fakecore], {
  cwd: SRCGO,
  env: { ...process.env, HOME: home },
  stdio: ['ignore', 'pipe', 'pipe'],
});
srv.stderr.on('data', d => process.stdout.write('[srv!] ' + d));
await waitPort(port, 30000);

let browser;
try {
  browser = await puppeteer.launch({
    executablePath: CHROME,
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu', '--window-size=1440,920'],
  });
  const page = await browser.newPage();
  await page.setViewport({ width: 1440, height: 920 });
  page.on('pageerror', e => console.log('[pageerror]', e.message));
  await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: 'networkidle0' });
  await page.waitForSelector('.main-content', { timeout: 30000 });

  const cd = await page.createCDPSession();
  await cd.send('Emulation.setTouchEmulationEnabled', { enabled: true, maxTouchPoints: 5 });

  const canvasTransform = () =>
    page.evaluate(() => {
      const c = document.querySelector('.canvas');
      return c ? c.style.transform : null;
    });

  // Point guaranteed to be outside any window: scan for a canvas spot.
  async function canvasPoint() {
    return page.evaluate(() => {
      for (const [x, y] of [[30, 60], [1400, 60], [30, 860], [1400, 860]]) {
        const el = document.elementFromPoint(x, y);
        if (el && !el.closest('.session-panel')) return { x, y };
      }
      return { x: 30, y: 60 };
    });
  }

  // ── 0. Setup: create the first session via MOUSE right-click menu ─
  console.log('== 0. setup: mouse right-click -> New Session -> Simple');
  await page.evaluate(() => {
    const el = document.elementFromPoint(30, 30);
    if (el) el.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, view: window, clientX: 30, clientY: 30 }));
  });
  await page.waitForSelector('.global-menu-panel', { timeout: 10000, visible: true });
  const itemBox = await page.$eval('.global-menu-item', el => {
    const r = el.getBoundingClientRect();
    return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
  });
  await cd.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: itemBox.x, y: itemBox.y });
  await sleep(400);
  await page.waitForSelector('.global-menu-submenu-item', { timeout: 5000, visible: true });
  const subBox = await page.$eval('.global-menu-submenu-item', el => {
    const r = el.getBoundingClientRect();
    return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
  });
  await cd.send('Input.dispatchMouseEvent', { type: 'mousePressed', x: subBox.x, y: subBox.y, button: 'left', clickCount: 1 });
  await cd.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: subBox.x, y: subBox.y, button: 'left', clickCount: 1 });
  await page.waitForSelector('.session-panel', { timeout: 15000, visible: true });
  console.log('  session created (mouse path OK)');

  // ── 1. Single-finger canvas pan ──────────────────────────────────
  console.log('== 1. single-finger pan');
  const p1 = await canvasPoint();
  await cd.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: p1.x, y: p1.y, id: 1 }] });
  await sleep(60);
  await cd.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x: p1.x + 60, y: p1.y + 30, id: 1 }] });
  await sleep(120);
  await cd.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  await sleep(200);
  let t = await canvasTransform();
  console.log('  transform after pan:', t);
  assert(t.includes('translate3d(60px, 30px'), 'finger pan did not move the canvas: ' + t);
  console.log('  pan OK');

  // ── 2. Long-press opens the global menu (touch right-click) ─────
  console.log('== 2. long-press menu');
  const p2 = await canvasPoint();
  await cd.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: p2.x, y: p2.y, id: 2 }] });
  await sleep(750); // 500ms long-press + slack
  const menuOpen = await page.evaluate(() => !!document.querySelector('.global-menu-panel'));
  console.log('  menu open:', menuOpen);
  assert(menuOpen, 'long-press did not open the global menu');
  await cd.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  await sleep(150);

  // ── 3. Tap-toggle the New Session submenu, then create a session ─
  console.log('== 3. tap New Session -> submenu -> Simple');
  const itemBox2 = await page.$eval('.global-menu-item', el => {
    const r = el.getBoundingClientRect();
    return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
  });
  await cd.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: itemBox2.x, y: itemBox2.y, id: 3 }] });
  await cd.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  await sleep(300);
  const submenuVisible = await page.evaluate(() => !!document.querySelector('.global-menu-submenu-item'));
  console.log('  submenu open:', submenuVisible);
  assert(submenuVisible, 'tapping New Session did not toggle the preset submenu');
  const subBox2 = await page.$eval('.global-menu-submenu-item', el => {
    const r = el.getBoundingClientRect();
    return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
  });
  const beforeCount = await page.evaluate(() => document.querySelectorAll('.session-panel').length);
  await cd.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: subBox2.x, y: subBox2.y, id: 4 }] });
  await cd.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  await sleep(800);
  const afterCount = await page.evaluate(() => document.querySelectorAll('.session-panel').length);
  console.log(`  session panels: ${beforeCount} -> ${afterCount}`);
  assert(afterCount > beforeCount, 'tap on preset did not create a session');

  // ── 4. Single-finger window drag (title bar) ─────────────────────
  console.log('== 4. single-finger window drag');
  // The topmost window is LAST in sessionOrder → last .session-bar in
  // DOM; the earlier windows may be covered by it.
  const bars = await page.$$('.session-bar');
  const topBar = bars[bars.length - 1];
  const barBox = await topBar.evaluate(el => {
    const r = el.getBoundingClientRect();
    return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
  });
  const before = await topBar.evaluate(el => {
    const r = el.closest('.session-panel').getBoundingClientRect();
    return { x: r.x, y: r.y };
  });
  await cd.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: barBox.x, y: barBox.y, id: 5 }] });
  await sleep(60);
  await cd.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x: barBox.x + 80, y: barBox.y + 50, id: 5 }] });
  await sleep(120);
  await cd.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  await sleep(200);
  const after = await topBar.evaluate(el => {
    const r = el.closest('.session-panel').getBoundingClientRect();
    return { x: r.x, y: r.y };
  });
  console.log(`  window ${JSON.stringify(before)} -> ${JSON.stringify(after)}`);
  assert(after.x - before.x > 50 && after.y - before.y > 30, 'finger window drag did not move the window');

  // ── 5. Two-finger pinch zoom ─────────────────────────────────────
  console.log('== 5. pinch zoom');
  const p5 = await canvasPoint();
  await cd.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: p5.x, y: p5.y, id: 6 }, { x: p5.x + 100, y: p5.y, id: 7 }] });
  await sleep(60);
  await cd.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x: p5.x - 50, y: p5.y, id: 6 }, { x: p5.x + 150, y: p5.y, id: 7 }] });
  await sleep(120);
  await cd.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  await sleep(250);
  t = await canvasTransform();
  console.log('  transform after pinch:', t);
  const m = t.match(/scale\(([0-9.]+)\)/);
  assert(m && parseFloat(m[1]) > 1.2, 'pinch did not zoom in: ' + t);
  console.log('  pinch OK');

  // ── 6. Mouse regression: right-click menu + left canvas pan ──────
  console.log('== 6. mouse regression (right-click menu, left pan)');
  await page.evaluate(() => {
    const el = document.elementFromPoint(60, 60);
    if (el) el.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, view: window, clientX: 60, clientY: 60 }));
  });
  await page.waitForSelector('.global-menu-panel', { timeout: 5000, visible: true });
  console.log('  mouse right-click menu OK');
  await page.evaluate(() => {
    const el = document.elementFromPoint(600, 600);
    if (el) el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window, clientX: 600, clientY: 600 }));
  });
  await sleep(150);
  const p6 = await canvasPoint();
  const tBefore = await canvasTransform();
  await cd.send('Input.dispatchMouseEvent', { type: 'mousePressed', x: p6.x, y: p6.y, button: 'left', clickCount: 1 });
  await cd.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: p6.x + 50, y: p6.y + 20, button: 'left' });
  await cd.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: p6.x + 50, y: p6.y + 20, button: 'left', clickCount: 1 });
  await sleep(200);
  const tAfter = await canvasTransform();
  console.log(`  transform ${tBefore} -> ${tAfter}`);
  assert(tBefore !== tAfter, 'left mouse pan regression: no movement');
  console.log('  mouse regression OK');

  await page.screenshot({ path: path.join(shots, 'final.png') });
  console.log('ALL PASS ✅');
} finally {
  if (browser) await browser.close();
  srv.kill();
  rmSync(tmp, { recursive: true, force: true });
}

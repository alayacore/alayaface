#!/usr/bin/env node
// Solo view E2E (F-series) — headless Chrome + Go backend + fakecore.
//
// Solo is a PRESENTATION state, so what matters is observable in the DOM:
// which elements exist and where they are. The Elm-side logic (the state
// machine, the geometry derivation, the gesture gating) is covered by
// tests/SoloViewTest.elm — this script covers the half no elm-test can see:
// that the rendered board really is one window filling the viewport, that the
// resize handles really are gone (SD6: not hidden, not rendered), and that
// exiting really does put every window back where the user left it.
//
// Flow:
//   1. build fakecore + Go server (fresh HOME), start both
//   2. create three sessions (global menu → New Session → first preset)
//   3. capture every panel's stored canvas rect + the canvas transform
//   4. ⤢ on the topmost panel → exactly ONE .session-panel, its client rect
//      == #main-content's, ZERO .resize-handle, no visible .connection-seg,
//      #main-content carries .main-content-solo
//   5. wheel does not zoom; dragging the bar does not move the window; both
//      leave the canvas transform and the stored rect untouched
//   6. ⤡ → every panel is back at its pre-solo coordinates, transform intact
//   7. Ctrl+Shift+F does the same thing from the keyboard, twice (toggle)
//   8. the global menu's "Solo window" item reaches solo with no panel click
//      (the ⋯ path, which is also the only way in when the bar scrolls off)
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

const tmp = mkdtempSync(path.join(tmpdir(), 'alayaface-solo-e2e-'));
const home = path.join(tmp, 'home');
const artifacts = path.join(tmp, 'shots');
execSync(`mkdir -p "${artifacts}" "${home}"`);
console.log('artifacts:', tmp);

const fakecore = path.join(tmp, 'fakecore');
const serverBin = path.join(tmp, 'alayaface-server');
execSync('go build -o "' + fakecore + '" ./internal/fakecore', { cwd: SRCGO, stdio: 'inherit' });
execSync('go build -o "' + serverBin + '" ./cmd/alayaface-server', { cwd: SRCGO, stdio: 'inherit' });

const port = await freePort();
const server = spawn(serverBin, ['--addr', `127.0.0.1:${port}`, '--static', '../src-elm', '--alayacore-bin', fakecore], {
  cwd: SRCGO,
  env: { ...process.env, HOME: home },
  stdio: ['ignore', 'pipe', 'pipe'],
});
server.stdout.on('data', d => process.stdout.write('[srv] ' + d));
server.stderr.on('data', d => process.stdout.write('[srv!] ' + d));

function cleanup() {
  try { server.kill('SIGTERM'); } catch {}
  try { rmSync(tmp, { recursive: true, force: true }); } catch {}
}

let browser;
try {
  await waitPort(port, 30000);
  browser = await puppeteer.launch({
    executablePath: CHROME,
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu', '--window-size=1440,920'],
  });
  const page = await browser.newPage();
  await page.setViewport({ width: 1440, height: 920 });
  page.on('pageerror', e => console.log('[pageerror]', e.message));
  page.on('console', m => { if (m.type() === 'error') console.log('[console.error]', m.text()); });
  await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: 'networkidle0' });
  await page.waitForSelector('.main-content', { timeout: 30000 });

  const waitFor = (sel, ms = 30000) => page.waitForSelector(sel, { timeout: ms, visible: true });
  const shot = name => page.screenshot({ path: path.join(artifacts, name) });

  const openGlobalMenu = async () => {
    await page.$eval('.main-content', el => el.dispatchEvent(
      new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 20, clientY: 20 })));
    await waitFor('.global-menu-panel');
  };
  const clickMenuItem = async text => {
    const items = await page.$$('.global-menu-item');
    for (const h of items) {
      if ((await h.evaluate(el => el.textContent || '')).includes(text)) { await h.click(); return true; }
    }
    return false;
  };
  const createSession = async label => {
    await openGlobalMenu();
    assert(await clickMenuItem('New Session'), 'New Session menu item');
    await sleep(250);
    const subs = await page.$$('.global-menu-submenu-item');
    assert(subs.length > 0, 'the preset flyout has items');
    await subs[0].click();
    await sleep(700);
    await waitFor('.session-panel');
    console.log(`  created ${label} via preset 1`);
  };

  // The canvas rect of every rendered window, keyed by data-session.
  // `style.left/top` is the layout store as Elm wrote it (INV1: the view
  // renders winRect, and in canvas view winRect IS the store) — exactly the
  // numbers that must be untouched across a solo round trip.
  const panelRects = () => page.evaluate(() => {
    const out = {};
    for (const el of document.querySelectorAll('.session-panel')) {
      out[el.getAttribute('data-session') || '?'] = [el.style.left, el.style.top, el.style.width, el.style.height];
    }
    return out;
  });
  const shell = () => page.evaluate(() => {
    const mc = document.querySelector('#main-content');
    const c = document.querySelector('.canvas');
    const r = mc.getBoundingClientRect();
    return {
      cls: mc.className,
      canvasCls: c ? c.className : null,
      transform: c ? c.style.transform : null,
      rect: { x: r.x, y: r.y, w: r.width, h: r.height },
      panels: document.querySelectorAll('.session-panel').length,
      handles: document.querySelectorAll('.resize-handle').length,
      // chain.js keeps its <svg> slots around and flips display — count the
      // VISIBLE ones, which is what the user sees (SD13).
      segs: [...document.querySelectorAll('.connection-seg')].filter(s => s.style.display !== 'none').length,
    };
  });
  const soloBtn = () => page.evaluate(() => {
    const bars = document.querySelectorAll('.session-bar');
    const bar = bars[bars.length - 1];           // topmost window (DOM order)
    if (!bar) return null;
    const btn = bar.querySelector('.session-bar-solo');
    if (!btn) return null;
    const r = btn.getBoundingClientRect();
    return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
  });  const clickAt = async (x, y) => {
    await page.mouse.move(x, y);
    await page.mouse.down();
    await sleep(60);
    await page.mouse.up();
    await sleep(400);
  };

  // ── 1. Three windows on the board ────────────────────────────────
  console.log('== 1. create three sessions');
  await createSession('first');
  await createSession('second');
  await createSession('third');
  const before = await panelRects();
  const shellBefore = await shell();
  console.log('  panels:', Object.keys(before).length, 'transform:', shellBefore.transform);
  assert(Object.keys(before).length === 3, `expected 3 windows, got ${Object.keys(before).length}`);
  assert(shellBefore.handles === 24, `expected 8 handles per window, got ${shellBefore.handles}`);

  // ── 2. ⤢ — one window, the viewport, no handles, no chain ───────
  console.log('== 2. enter solo via the ⤢ button');
  const b1 = await soloBtn();
  assert(b1, 'the topmost window bar has a .session-bar-solo button');
  await clickAt(b1.x, b1.y);
  await sleep(400);
  let s = await shell();
  console.log('  shell:', JSON.stringify(s));
  assert(s.panels === 1, `solo must render exactly one panel, got ${s.panels}`);
  assert(/main-content-solo/.test(s.cls), '#main-content lost the solo class');
  assert(s.handles === 0, `solo must not render resize handles, got ${s.handles}`);
  assert(s.segs === 0, `solo must clear the connection chain, got ${s.segs} visible segments`);
  const soloRect = await page.evaluate(() => {
    const p = document.querySelector('.session-panel').getBoundingClientRect();
    const m = document.querySelector('#main-content').getBoundingClientRect();
    return { panel: { x: p.x, y: p.y, w: p.width, h: p.height }, shell: { x: m.x, y: m.y, w: m.width, h: m.height } };
  });
  console.log('  panel vs #main-content:', JSON.stringify(soloRect));
  // 2px tolerance: the rect is canvas-scaled and rounded (soloRect divides by
  // canvasScale), so the edges can land a pixel off at fractional scales.
  const near = (a, b) => Math.abs(a - b) <= 2;
  assert(near(soloRect.panel.w, soloRect.shell.w), `solo width ${soloRect.panel.w} != viewport ${soloRect.shell.w}`);
  assert(near(soloRect.panel.h, soloRect.shell.h), `solo height ${soloRect.panel.h} != viewport ${soloRect.shell.h}`);
  assert(near(soloRect.panel.x, soloRect.shell.x) && near(soloRect.panel.y, soloRect.shell.y), 'solo panel is not at the viewport origin');
  await shot('02-solo.png');

  // ── 3. Gestures are refused (SD7: Elm decides, the pipe keeps sending) ──
  console.log('== 3. wheel zoom and bar drag are no-ops in solo');
  // A real mouse wheel over the panel never reaches the zoom port at all
  // (transport.js leaves windows to native scrolling), so that half proves
  // nothing about the Elm gate. Dispatch the wheel ON #main-content instead:
  // the listener does not filter it, `CanvasZoom` is sent, and dropping it is
  // purely Elm's decision.
  await page.mouse.move(720, 500);
  await page.mouse.wheel({ deltaY: -400 });
  await page.evaluate(() => {
    document.querySelector('#main-content').dispatchEvent(
      new WheelEvent('wheel', { bubbles: true, cancelable: true, deltaY: -500, clientX: 700, clientY: 500 }));
  });
  await sleep(300);
  let s2 = await shell();
  assert(s2.transform === shellBefore.transform, `solo wheel zoomed the canvas: ${shellBefore.transform} -> ${s2.transform}`);
  const bar = await page.evaluate(() => {
    const r = document.querySelector('.session-bar').getBoundingClientRect();
    return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
  });
  const storedSolo = await panelRects();
  await page.mouse.move(bar.x, bar.y);
  await page.mouse.down();
  await page.mouse.move(bar.x + 150, bar.y + 90, { steps: 6 });
  await page.mouse.up();
  await sleep(300);
  s2 = await shell();
  assert(s2.transform === shellBefore.transform, 'solo bar drag panned/zoomed the canvas');
  assert(JSON.stringify(await panelRects()) === JSON.stringify(storedSolo), 'solo bar drag wrote a new rect into the layout store');
  assert(s2.panels === 1, 'a gesture made windows appear');
  console.log('  no zoom, no move, no layout write: OK');

  // ── 4. ⤡ — the board comes back intact ──────────────────────────
  console.log('== 4. exit solo via the ⤡ button');
  const b2 = await soloBtn();
  assert(b2, 'the solo window bar still has the (now ⤡) button');
  await clickAt(b2.x, b2.y);
  await sleep(400);
  const after = await panelRects();
  s = await shell();
  console.log('  panels:', s.panels, 'handles:', s.handles, 'transform:', s.transform);
  assert(s.panels === 3, `exit must bring back 3 panels, got ${s.panels}`);
  assert(!/main-content-solo/.test(s.cls), 'the solo class survived exit');
  assert(s.handles === 24, `handles must come back, got ${s.handles}`);
  assert(JSON.stringify(after) === JSON.stringify(before), `layout moved across a solo round trip:\n  before ${JSON.stringify(before)}\n  after  ${JSON.stringify(after)}`);
  assert(s.transform === shellBefore.transform, `canvas transform moved across a solo round trip: ${shellBefore.transform} -> ${s.transform}`);
  await shot('04-restored.png');

  // The control for step 3: the SAME wheel dispatch on the SAME element does
  // zoom now that solo is over — otherwise step 3 would only have proven that
  // the port never fires (a broken listener passes it too).
  console.log('== 4b. the same wheel DOES zoom outside solo');
  await page.evaluate(() => {
    document.querySelector('#main-content').dispatchEvent(
      new WheelEvent('wheel', { bubbles: true, cancelable: true, deltaY: -500, clientX: 700, clientY: 500 }));
  });
  await sleep(300);
  const zoomed = await shell();
  assert(zoomed.transform !== shellBefore.transform, 'the canvas wheel did not zoom outside solo — step 3 proved nothing');
  console.log('  transform:', shellBefore.transform, '->', zoomed.transform);
  // Reset the scale through the menu (the app's own control). The OFFSET is
  // not expected to return to its original value — zoom-reset keeps the
  // viewport centre fixed — so only the scale is asserted, and every later
  // comparison in this file is on canvas coordinates (style.left/top), which
  // a scale change does not touch.
  await openGlobalMenu();
  assert(await clickMenuItem('Zoom'), 'no zoom-reset menu item to restore the scale');
  await sleep(300);
  const scale = await page.evaluate(() => {
    const t = document.querySelector('.canvas').style.transform || '';
    const m = t.match(/scale\(([^)]+)\)/);
    return m ? parseFloat(m[1]) : null;
  });
  assert(Math.abs(scale - 1) < 0.001, `zoom reset left the scale at ${scale}`);

  // ── 5. Ctrl+Shift+F is a toggle ──────────────────────────────────
  console.log('== 5. Ctrl+Shift+F enters AND exits solo');
  await page.keyboard.down('Control');
  await page.keyboard.down('Shift');
  await page.keyboard.press('KeyF');
  await page.keyboard.up('Shift');
  await page.keyboard.up('Control');
  await sleep(400);
  s = await shell();
  assert(s.panels === 1, `Ctrl+Shift+F did not enter solo (panels: ${s.panels})`);
  await page.keyboard.down('Control');
  await page.keyboard.down('Shift');
  await page.keyboard.press('KeyF');
  await page.keyboard.up('Shift');
  await page.keyboard.up('Control');
  await sleep(400);
  s = await shell();
  assert(s.panels === 3, `Ctrl+Shift+F did not exit solo (panels: ${s.panels})`);
  assert(JSON.stringify(await panelRects()) === JSON.stringify(before), 'the shortcut moved the layout');
  console.log('  chord toggles both ways, layout intact');

  // ── 6. plain Ctrl+F must NOT be hijacked (browser find) ─────────
  console.log('== 6. Ctrl+F alone stays free');
  await page.keyboard.down('Control');
  await page.keyboard.press('KeyF');
  await page.keyboard.up('Control');
  await sleep(300);
  s = await shell();
  assert(s.panels === 3, `Ctrl+F entered solo (panels: ${s.panels})`);

  // ── 7. the global menu path (no window click needed) ────────────
  console.log('== 7. the global menu opens solo');
  await openGlobalMenu();
  assert(await clickMenuItem('Solo window'), 'the global menu has no "Solo window" item');
  await sleep(400);
  s = await shell();
  assert(s.panels === 1, `the menu item did not enter solo (panels: ${s.panels})`);
  // …and from solo the menu is still reachable (SD11): the item now reads
  // "Exit solo", which is the only canvas control there.
  await openGlobalMenu();
  assert(await clickMenuItem('Exit solo'), 'in solo the menu lost its "Exit solo" item');
  await sleep(400);
  s = await shell();
  assert(s.panels === 3, `the menu item did not exit solo (panels: ${s.panels})`);
  assert(JSON.stringify(await panelRects()) === JSON.stringify(before), 'the menu path moved the layout');
  await shot('07-done.png');

  // ── 8. closing the solo window exits solo (SD9) ─────────────────
  console.log('== 8. closing the solo window exits solo');
  const b3 = await soloBtn();
  await clickAt(b3.x, b3.y);
  await sleep(300);
  assert((await shell()).panels === 1, 'did not enter solo before the close test');
  const closeBtn = await page.evaluate(() => {
    const r = document.querySelector('.session-bar-close').getBoundingClientRect();
    return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
  });
  await clickAt(closeBtn.x, closeBtn.y);
  await sleep(300);
  // The confirm overlay is a window action, so it stays reachable in solo;
  // "Close" is its autofocused default, so Enter confirms it (same contract
  // close-confirm-e2e.mjs pins).
  await waitFor('.overlay .confirm-page-buttons button');
  await page.keyboard.press('Enter');
  await sleep(900);
  s = await shell();
  const left = await panelRects();
  console.log('  after closing the solo window — panels:', s.panels, 'cls:', s.cls);
  assert(s.panels === 2, `closing the solo window must leave 2 panels, got ${s.panels}`);
  assert(!/main-content-solo/.test(s.cls), 'solo survived the death of its window (SD9)');
  const rest = Object.fromEntries(Object.entries(before).filter(k => k[0] in left));
  assert(JSON.stringify(left) === JSON.stringify(rest), 'the surviving windows moved when the solo one closed');

  await shot('08-final.png');
  console.log('ALL PASS');
} catch (err) {
  console.error('E2E FAILED:', err.message);
  try { await page.screenshot({ path: path.join(artifacts, 'failure.png') }); } catch {}
  process.exitCode = 1;
} finally {
  if (browser) await browser.close();
  cleanup();
}

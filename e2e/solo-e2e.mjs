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
//   4. ⤢ on a panel → exactly ONE .session-panel, its client rect ==
//      #main-content's, ZERO .resize-handle, no visible .connection-seg,
//      #main-content carries .main-content-solo
//   5. wheel does not zoom and the bar cannot be dragged — and neither writes
//      anything into the layout store or the canvas transform
//   6. ⤡ → every panel is back at its pre-solo coordinates, transform intact
//   6b. the CONTROL for 5: the same synthetic wheel DOES zoom outside solo
//       (without it, "the wheel did nothing" would also be satisfied by a
//       listener that never fires)
//   7. Ctrl+Shift+F toggles both ways; plain Ctrl+F is not hijacked
//   8. the global menu's item reaches solo and back with no panel click
//   9. closing the solo window exits solo (SD9) and leaves the others intact
//  10. SD11: a file picker left open in a window that solo hides makes the exit
//      control read "Canvas · 1 waiting" (highlighted); clicking it returns to
//      the canvas with that prompt reachable — and SD10/SD12: Ctrl+W exits
//      solo instead of opening a close confirmation, Escape closes an overlay
//      first and solo second
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

  // ── 9. SD11: a hidden window stalled on the user is reported ────
  // The overlay is rendered INSIDE the session panel, so when that panel is
  // hidden the prompt vanishes with it and the session waits forever with
  // nothing on screen to say so. The exit control has to carry that number.
  console.log('== 9. a hidden modal is reported by the exit control');
  const ids = Object.keys(await panelRects());
  assert(ids.length >= 2, 'need two windows for the reachability test');

  // Click by ELEMENT, not by pixel, for anything that may sit under another
  // window: panels cascade 50×40, so an older window's footer is covered and a
  // coordinate click would land on the window above it. (Entering/leaving solo
  // is then clicked for real — in solo nothing can be in the way.)
  //
  // WHICH panel ends up hosting the picker is read back from the DOM rather
  // than assumed: the mousedown that comes with the click activates and RAISES
  // that session, and raising reorders the panels, so "the first panel" is not
  // a stable identity mid-test. Same for the solo target.
  const clickEl = async selector => {
    const ok = await page.evaluate(sel => {
      const el = document.querySelector(sel);
      if (!el) return false;
      el.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
      el.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true }));
      el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
      return true;
    }, selector);
    await sleep(450);
    return ok;
  };
  const overlayIn = id =>
    page.evaluate(sel => !!document.querySelector(`${sel} .overlay`), `.session-panel[data-session="${id}"]`);

  // `.footer-btn` #1 is the paperclip → OpenFilePicker for that session.
  assert(await clickEl('.session-panel .footer-btn'), 'no attach button in the first panel');
  const hiddenId = await page.evaluate(() => {
    const o = document.querySelector('.overlay');
    const host = o && o.closest('.session-panel');
    return host ? host.getAttribute('data-session') : null;
  });
  assert(hiddenId, 'the file picker did not open anywhere');
  const soloId = ids.find(id => id !== hiddenId);
  assert(soloId, 'no second window to solo');
  console.log(`  picker waits in ${hiddenId}; solo will cover it with ${soloId}`);

  // Now solo the OTHER window: the picker — and the session waiting on it —
  // disappear with the panel.
  assert(await clickEl(`.session-panel[data-session="${soloId}"] .session-bar-solo`), 'no solo button on the other panel');
  s = await shell();
  assert(s.panels === 1, `expected solo on ${soloId}, panels: ${s.panels}`);
  assert(!(await overlayIn(hiddenId)), 'the hidden panel is still rendered (SD6)');
  const badge = await page.evaluate(() => {
    const el = document.querySelector('.session-bar-solo');
    return el
      ? {
          text: (el.textContent || '').trim(),
          hot: el.classList.contains('solo-attention'),
          title: el.getAttribute('title') || '',
          menu: !!document.querySelector('.session-bar-menu'),
        }
      : null;
  });
  console.log('  exit control:', JSON.stringify(badge));
  assert(badge, 'the solo bar has no exit control');
  assert(/1 waiting/.test(badge.text), `the exit control does not report the hidden prompt: "${badge.text}"`);
  assert(badge.hot, 'waiting > 0 must be highlighted (it means something is blocked on you)');
  assert(/waiting for an answer/.test(badge.title), `the tooltip does not explain the number: "${badge.title}"`);
  assert(badge.menu, 'no ⋯ menu button in the solo bar (SD11: the canvas has no right-click here)');
  await shot('09-attention.png');

  // …and clicking IT leaves solo with the prompt reachable again. This one IS
  // a real pointer click: the control is on screen by definition.
  const badgePos = await page.evaluate(() => {
    const r = document.querySelector('.session-bar-solo').getBoundingClientRect();
    return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
  });
  await clickAt(badgePos.x, badgePos.y);
  await sleep(400);
  s = await shell();
  assert(s.panels === ids.length, `the exit control did not return to the canvas (${s.panels} panels)`);
  assert(await overlayIn(hiddenId), 'after exiting solo the hidden session\'s picker is still unreachable');
  console.log('  hidden prompt reported, then reached: OK');
  // Close the picker so it stops counting in the next section (Escape is the
  // chain's own file-picker step, so this also proves the picker is the active
  // session's overlay and not a stray element).
  await page.keyboard.press('Escape');
  await sleep(300);
  assert((await overlayIn(hiddenId)) === false, 'the picker is still open — later sections would miscount');

  // ── 10. SD10 (revised): Ctrl+W closes NOTHING, in either view ───
  // Canvas view first: the chord must be inert — no panel disappears, no
  // confirmation opens. That binding used to close the topmost window, which
  // made a reflex borrowed from the browser a way to lose a session.
  console.log('== 10. Ctrl+W closes nothing; Esc exits solo last');
  const enterSoloOn = id => clickEl(`.session-panel[data-session="${id}"] .session-bar-solo`);
  const rectsNow = await panelRects();
  await page.keyboard.down('Control');
  await page.keyboard.press('KeyW');
  await page.keyboard.up('Control');
  await sleep(400);
  s = await shell();
  let overlays = await page.evaluate(() => document.querySelectorAll('.overlay').length);
  assert(s.panels === ids.length, `Ctrl+W closed a window in canvas view (panels: ${s.panels})`);
  assert(overlays === 0, `Ctrl+W opened a confirmation in canvas view (${overlays} overlay(s))`);
  assert(JSON.stringify(await panelRects()) === JSON.stringify(rectsNow), 'Ctrl+W moved the layout in canvas view');
  console.log('  canvas view: Ctrl+W did nothing at all');

  // In solo it is still allowed to do the one thing that destroys nothing:
  // return to the canvas.
  assert(await enterSoloOn(soloId), 'setup: no solo button');
  assert((await shell()).panels === 1, 'Ctrl+W setup: not solo');
  await page.keyboard.down('Control');
  await page.keyboard.press('KeyW');
  await page.keyboard.up('Control');
  await sleep(400);
  s = await shell();
  overlays = await page.evaluate(() => document.querySelectorAll('.overlay').length);
  assert(s.panels === ids.length, `Ctrl+W closed the window instead of exiting solo (panels: ${s.panels})`);
  assert(overlays === 0, `Ctrl+W in solo opened a close confirmation (${overlays} overlay(s))`);
  console.log('  solo: Ctrl+W returned to the canvas and closed nothing');

  // Escape exits solo, but only as the LAST step of the overlay chain: with a
  // confirmation open on the solo window itself, the first Escape dismisses
  // THAT and solo survives (SD12).
  await enterSoloOn(soloId);
  assert((await shell()).panels === 1, 'Esc setup: not solo');
  assert(await clickEl(`.session-panel[data-session="${soloId}"] .session-bar-close`), 'no ✕ on the solo panel');
  assert(await overlayIn(soloId), 'setup: the solo window\'s close confirmation did not open');
  await page.keyboard.press('Escape');
  await sleep(300);
  assert((await shell()).panels === 1, 'Escape closed the confirmation AND exited solo at once');
  assert((await overlayIn(soloId)) === false, 'the close confirmation survived its Escape');
  await page.keyboard.press('Escape');
  await sleep(300);
  assert((await shell()).panels === ids.length, 'Escape did not exit solo as the LAST step');
  console.log('  Escape ordering: overlay first, solo second');

  console.log('ALL PASS');
} catch (err) {
  console.error('E2E FAILED:', err.message);
  try { await page.screenshot({ path: path.join(artifacts, 'failure.png') }); } catch {}
  process.exitCode = 1;
} finally {
  if (browser) await browser.close();
  cleanup();
}

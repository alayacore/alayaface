#!/usr/bin/env node
// Solo view E2E (F-series) — headless Chrome + Go backend + fakecore.
//
// Solo is a PRESENTATION state, so what matters is observable in the DOM:
// which elements exist and where they are. The Elm side (state machine,
// geometry derivation, gesture gating, the attention counts) is covered by
// tests/SoloViewTest.elm; this file covers the half no elm-test can see — that
// the rendered board really is one window filling the viewport, that hidden
// windows and their resize handles are absent from the DOM rather than styled
// away, and that the view can only be left by pointing at a control.
//
// Flow (the § numbers match the console output):
//   1. build fakecore + the Go server (fresh HOME), start both, open a tab
//   2. create three sessions from the global menu
//   3. ⤢  → exactly ONE .session-panel, its client rect == #main-content's,
//      ZERO .resize-handle, no visible .connection-seg, shell carries
//      .main-content-solo  (SD6/SD13/INV5)
//   4. wheel zoom and a bar drag are refused, and neither writes anything into
//      the layout store or the canvas transform                    (SD7/INV4)
//   5. ⤡ → every panel is back at its pre-solo coordinates and transform
//   6. Ctrl+Shift+F ENTERS solo and cannot leave it: pressed again and again,
//      then Ctrl+[ and Escape — the view stays. The chord's own exit half was
//      removed by SD18.                                              (SD18)
//   7. plain Ctrl+F is still the browser's
//   8. the global menu path, entered and left with no panel click
//   9. SD19: solo renders NO ✕ at all — the bar's only controls are the exit
//      button and the menu button. Leaving solo brings the ✕ back, and closing
//      there leaves the other windows exactly where they were.
//  10. SD11: a file picker left open in a window that solo hides makes the exit
//      control read "Canvas · 1 waiting", highlighted; clicking it returns to
//      the canvas with that prompt reachable
//  11. SD10/SD18 with a real browser: Ctrl+W is inert in canvas view and cannot
//      leave solo; Escape closes an open overlay and then stops. Then the two
//      pointer exits — ⤡ and the ⋯ menu's "Exit solo" — with the topmost window
//      deliberately NOT the solo one, which is how the menu's target bug was
//      found: leaving must leave, not jump solo onto an invisible window.
//  12. SD9 from inside solo: the window can still die with no ✕ involved
//      (deleted from the Session Manager, which the ⋯ button keeps reachable),
//      and the view must not outlive it.
//
// Two things this harness learned the hard way and keeps doing, because both
// silently produced false results:
//   - panels cascade 50×40, so an older window's footer sits UNDER a newer one.
//     Anything that may be covered is clicked through the DOM (clickEl), not at
//     its coordinates. Coordinate clicks are reserved for controls that are
//     provably on top — that fidelity matters exactly where the assertion is
//     about a real pointer affordance.
//   - a click that lands on a panel ACTIVATES and RAISES it, which reorders
//     sessionOrder. So "which panel is which" is read back from the DOM after
//     the click rather than assumed from the order before it.
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
server.stderr.on('data', d => { const t = String(d); if (!t.includes('[tlv]') && !t.includes('[rpc]')) process.stdout.write('[srv!] ' + t); });

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

  // ── helpers ───────────────────────────────────────────────────────
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
      transform: c ? c.style.transform : null,
      rect: { x: r.x, y: r.y, w: r.width, h: r.height },
      panels: document.querySelectorAll('.session-panel').length,
      handles: document.querySelectorAll('.resize-handle').length,
      // chain.js keeps its <svg> slots and flips display, so count the VISIBLE
      // ones — that is what the user sees (SD13).
      segs: [...document.querySelectorAll('.connection-seg')].filter(s => s.style.display !== 'none').length,
    };
  });
  // A real pointer click: used for controls that are provably on top, because
  // the assertion is about the affordance working under a pointer.
  const clickAt = async (x, y) => {
    await page.mouse.move(x, y);
    await page.mouse.down();
    await sleep(60);
    await page.mouse.up();
    await sleep(400);
  };
  const centerOf = sel => page.evaluate(s => {
    const el = document.querySelector(s);
    if (!el) return null;
    const r = el.getBoundingClientRect();
    return { x: r.x + r.width / 2, y: r.y + r.height / 2, w: r.width, h: r.height };
  }, sel);
  // Click through the DOM: works for an element another window is covering, and
  // for a hidden one (which must NOT be clickable — asserting null there is the
  // SD6 check).
  const clickEl = async sel => {
    const ok = await page.evaluate(s => {
      const el = document.querySelector(s);
      if (!el) return false;
      for (const type of ['mousedown', 'mouseup', 'click']) {
        el.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true }));
      }
      return true;
    }, sel);
    await sleep(420);
    return ok;
  };
  const hasEl = sel => page.evaluate(s => !!document.querySelector(s), sel);
  const overlayIn = id => hasEl(`.session-panel[data-session="${id}"] .overlay`);
  const openGlobalMenu = async () => {
    await page.$eval('.main-content', el => el.dispatchEvent(
      new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 20, clientY: 20 })));
    await waitFor('.global-menu-panel');
  };
  const clickMenuItem = async text => {
    const items = await page.$$('.global-menu-item');
    for (const h of items) {
      if ((await h.evaluate(el => el.textContent || '')).includes(text)) { await h.click(); await sleep(400); return true; }
    }
    return false;
  };
  const createSession = async label => {
    await openGlobalMenu();
    assert(await clickMenuItem('New Session'), 'New Session menu item');
    await sleep(300);
    const subs = await page.$$('.global-menu-submenu-item');
    assert(subs.length > 0, 'the preset flyout has items');
    await subs[0].click();
    await waitFor('.session-panel');
    await sleep(700);
    console.log(`  created ${label}`);
  };
  const chord = async (mods, code) => {
    for (const m of mods) await page.keyboard.down(m);
    await page.keyboard.press(code);
    for (const m of [...mods].reverse()) await page.keyboard.up(m);
    await sleep(380);
  };
  const soloBtn = id => centerOf(`.session-panel[data-session="${id}"] .session-bar-solo`);
  const near = (a, b) => Math.abs(a - b) <= 2;

  // ── 1–2. three windows on the board ───────────────────────────────
  console.log('== 1. create three sessions');
  await createSession('first');
  await createSession('second');
  await createSession('third');
  const before = await panelRects();
  const ids = Object.keys(before);
  const shellBefore = await shell();
  console.log(`  panels: ${ids.length}, transform: ${shellBefore.transform}`);
  assert(ids.length === 3, `expected 3 windows, got ${ids.length}`);
  assert(shellBefore.handles === 24, `expected 8 handles per window, got ${shellBefore.handles}`);
  assert(!/main-content-solo/.test(shellBefore.cls), 'canvas view carries the solo class');

  // ── 3. ⤢ — one window, the viewport, nothing else ────────────────
  console.log('== 2. enter solo via the ⤢ button');
  const topId = ids[ids.length - 1];
  const b1 = await soloBtn(topId);
  assert(b1, 'no .session-bar-solo button on a window bar');
  await clickAt(b1.x, b1.y);
  let s = await shell();
  console.log('  shell:', JSON.stringify(s));
  assert(s.panels === 1, `solo must render exactly one panel, got ${s.panels}`);
  assert(/main-content-solo/.test(s.cls), '#main-content lost the solo class (INV5: the shell stays)');
  assert(s.handles === 0, `solo must not render resize handles, got ${s.handles}`);
  assert(s.segs === 0, `solo must clear the connection chain, got ${s.segs} visible segments`);
  const fit = await page.evaluate(() => {
    const p = document.querySelector('.session-panel').getBoundingClientRect();
    const m = document.querySelector('#main-content').getBoundingClientRect();
    return { pw: p.width, ph: p.height, sw: m.width, sh: m.height, px: p.x, py: p.y };
  });
  assert(near(fit.pw, fit.sw) && near(fit.ph, fit.sh), `solo panel is not the viewport: ${JSON.stringify(fit)}`);
  assert(near(fit.px, 0) && near(fit.py, 0), `solo panel is not at the viewport origin: ${JSON.stringify(fit)}`);
  await shot('02-solo.png');

  // ── 4. gestures refused, and nothing written ─────────────────────
  console.log('== 3. wheel zoom and bar drag are no-ops in solo');
  const storedSolo = await panelRects();
  // A real wheel over the panel is left to native scrolling by transport.js, so
  // it proves nothing about the Elm gate. Dispatch it on #main-content instead:
  // the listener forwards that, and dropping it is Elm's decision (SD7).
  await page.mouse.move(720, 500);
  await page.mouse.wheel({ deltaY: -400 });
  await page.evaluate(() => {
    document.querySelector('#main-content').dispatchEvent(
      new WheelEvent('wheel', { bubbles: true, cancelable: true, deltaY: -500, clientX: 700, clientY: 500 }));
  });
  await sleep(350);
  s = await shell();
  assert(s.transform === shellBefore.transform, `solo wheel zoomed the canvas: ${shellBefore.transform} -> ${s.transform}`);
  const bar = await centerOf('.session-bar');
  await page.mouse.move(bar.x, bar.y);
  await page.mouse.down();
  await page.mouse.move(bar.x + 150, bar.y + 90, { steps: 6 });
  await page.mouse.up();
  await sleep(350);
  s = await shell();
  assert(s.transform === shellBefore.transform, 'solo bar drag panned the canvas');
  assert(JSON.stringify(await panelRects()) === JSON.stringify(storedSolo), 'solo bar drag wrote a rect');
  assert(s.panels === 1, 'a gesture made a hidden window reappear');
  console.log('  no zoom, no move, no layout write');

  // ── 5. ⤡ restores the board exactly ──────────────────────────────
  console.log('== 4. exit solo via the ⤡ button');
  const b2 = await soloBtn(topId);
  await clickAt(b2.x, b2.y);
  s = await shell();
  assert(s.panels === 3, `exit must bring back 3 panels, got ${s.panels}`);
  assert(s.handles === 24, `handles must come back, got ${s.handles}`);
  assert(!/main-content-solo/.test(s.cls), 'the solo class survived exit');
  assert(JSON.stringify(await panelRects()) === JSON.stringify(before), 'the layout moved across a solo round trip');
  assert(s.transform === shellBefore.transform, 'the canvas transform moved across a solo round trip');
  await shot('05-restored.png');

  // The CONTROL for §3: the same synthetic wheel on the same element DOES zoom
  // outside solo. Without this, "the wheel did nothing" would also be satisfied
  // by a listener that never fires at all.
  console.log('== 4b. the same wheel DOES zoom outside solo');
  await page.evaluate(() => {
    document.querySelector('#main-content').dispatchEvent(
      new WheelEvent('wheel', { bubbles: true, cancelable: true, deltaY: -500, clientX: 700, clientY: 500 }));
  });
  await sleep(350);
  const zoomed = await shell();
  assert(zoomed.transform !== shellBefore.transform, 'the canvas wheel did not zoom outside solo — §3 proved nothing');
  console.log(`  ${shellBefore.transform} -> ${zoomed.transform}`);
  // Reset the scale with the app's own control. Only the SCALE is asserted:
  // zoom-reset keeps the viewport centre fixed, so the offset legitimately
  // differs from the original, and every later comparison here is on canvas
  // coordinates, which a scale change does not touch.
  await openGlobalMenu();
  assert(await clickMenuItem('Zoom'), 'no zoom-reset menu item');
  const scale = await page.evaluate(() => {
    const m = (document.querySelector('.canvas').style.transform || '').match(/scale\(([^)]+)\)/);
    return m ? parseFloat(m[1]) : null;
  });
  assert(Math.abs(scale - 1) < 0.001, `zoom reset left the scale at ${scale}`);

  // ── 6. SD18: the chord enters, and cannot leave ──────────────────
  console.log('== 5. Ctrl+Shift+F enters solo; no chord leaves it');
  await chord(['Control', 'Shift'], 'KeyF');
  assert((await shell()).panels === 1, 'Ctrl+Shift+F did not enter solo');
  await chord(['Control', 'Shift'], 'KeyF');
  await chord(['Control', 'Shift'], 'KeyF');
  assert((await shell()).panels === 1, 'Ctrl+Shift+F toggled solo off — SD18 forbids it');
  await chord(['Control'], 'BracketLeft');
  assert((await shell()).panels === 1, 'Ctrl+[ left solo');
  await page.keyboard.press('Escape');
  await sleep(350);
  assert((await shell()).panels === 1, 'Escape left solo');
  console.log('  survived Ctrl+Shift+F ×3, Ctrl+[ and Escape');
  const exitBtn = await soloBtn(topId);
  await clickAt(exitBtn.x, exitBtn.y);
  assert((await shell()).panels === 3, 'the ⤡ button did not leave solo');
  console.log('  the ⤡ button leaves; the chords do not');

  // ── 7. Ctrl+F is still the browser's ─────────────────────────────
  console.log('== 6. Ctrl+F alone stays free');
  await chord(['Control'], 'KeyF');
  assert((await shell()).panels === 3, 'Ctrl+F entered solo (browser find hijacked)');

  // ── 8. the global menu path, both directions ─────────────────────
  console.log('== 7. the global menu path (no window click needed)');
  await openGlobalMenu();
  assert(await clickMenuItem('Solo window'), 'the global menu has no "Solo window" item');
  assert((await shell()).panels === 1, 'the menu item did not enter solo');
  await openGlobalMenu();
  assert(await clickMenuItem('Exit solo'), 'in solo the menu lost its "Exit solo" item');
  s = await shell();
  assert(s.panels === 3, 'the menu item did not exit solo');
  assert(JSON.stringify(await panelRects()) === JSON.stringify(before), 'the menu path moved the layout');
  console.log('  menu enters and leaves, layout untouched');

  // ── 9. SD19: solo has no ✕, and closing is a canvas-view act ─────
  console.log('== 8. no close button while solo');
  const b3 = await soloBtn(topId);
  await clickAt(b3.x, b3.y);
  assert((await shell()).panels === 1, 'did not enter solo before the close test');
  // The whole rule is one element's absence: in solo the bar carries ⤡ and ⋯
  // and nothing that destroys a window. Closing the session you are looking
  // at — with the board invisible behind it — is the accident SD18/SD10 have
  // been steering around since solo shipped; the user removed the last of it.
  assert(!(await hasEl('.session-bar-close')), 'a solo window still renders a ✕ (SD19)');
  assert(await hasEl('.session-bar-solo'), 'solo lost its exit control');
  assert(await hasEl('.session-bar-menu'), 'solo lost its ⋯ menu button (SD11)');
  console.log('  the solo bar offers no ✕');
  // Leaving solo brings it back — the ✕ is the canvas's control, not gone.
  const b3exit = await soloBtn(topId);
  await clickAt(b3exit.x, b3exit.y);
  assert((await shell()).panels === 3, 'setup: did not leave solo before the close test');
  assert(await hasEl(`.session-panel[data-session="${topId}"] .session-bar-close`),
    'exiting solo did not restore the ✕');
  await clickEl(`.session-panel[data-session="${topId}"] .session-bar-close`);
  await waitFor('.overlay .confirm-page-buttons button');
  await page.keyboard.press('Enter');   // "Close" is the autofocused default
  await sleep(900);
  s = await shell();
  const left = await panelRects();
  console.log(`  after closing the window from canvas view — panels: ${s.panels}, cls: ${s.cls}`);
  assert(s.panels === 2, `closing a window must leave 2 panels, got ${s.panels}`);
  assert(!/main-content-solo/.test(s.cls), 'solo survived the death of its window (SD9)');
  const survivors = Object.fromEntries(Object.entries(before).filter(k => k[0] in left));
  assert(JSON.stringify(left) === JSON.stringify(survivors), 'the surviving windows moved when one closed');

  // ── 10. SD11: a hidden prompt is reported, then reachable ────────
  console.log('== 9. a hidden modal is reported by the exit control');
  const ids2 = Object.keys(left);
  const hiddenId = ids2[0];
  const soloId2 = ids2[ids2.length - 1];
  // `.footer-btn` #1 is the paperclip → OpenFilePicker for that session. The
  // click also ACTIVATES and RAISES it, so which panel ends up hosting the
  // picker is read back afterwards instead of assumed.
  assert(await clickEl('.session-panel .footer-btn'), 'no attach button in a panel');
  const hostId = await page.evaluate(() => {
    const o = document.querySelector('.overlay');
    const host = o && o.closest('.session-panel');
    return host ? host.getAttribute('data-session') : null;
  });
  assert(hostId, 'the file picker did not open anywhere');
  const otherId = ids2.find(id => id !== hostId);
  assert(otherId, 'need a second window to solo');
  console.log(`  picker waits in ${hostId}; solo will hide it behind ${otherId}`);
  assert(await clickEl(`.session-panel[data-session="${otherId}"] .session-bar-solo`), 'no solo button');
  assert((await shell()).panels === 1, 'did not enter solo on the other window');
  assert(!(await overlayIn(hostId)), 'the hidden panel is still rendered (SD6)');
  const badge = await page.evaluate(() => {
    const el = document.querySelector('.session-bar-solo');
    return el ? {
      text: (el.textContent || '').trim(),
      hot: el.classList.contains('solo-attention'),
      title: el.getAttribute('title') || '',
      menu: !!document.querySelector('.session-bar-menu'),
    } : null;
  });
  console.log('  exit control:', JSON.stringify(badge));
  assert(badge, 'the solo bar has no exit control');
  assert(/1 waiting/.test(badge.text), `the exit control does not report the hidden prompt: "${badge.text}"`);
  assert(badge.hot, 'waiting > 0 must be highlighted');
  assert(/waiting for an answer/.test(badge.title), `the tooltip does not explain the number: "${badge.title}"`);
  assert(!/\bEsc\b/.test(badge.title), `the tooltip still advertises Escape as an exit (SD18): "${badge.title}"`);
  assert(badge.menu, 'no ⋯ menu button in the solo bar (SD11)');
  await shot('09-attention.png');
  const badgePos = await centerOf('.session-bar-solo');
  await clickAt(badgePos.x, badgePos.y);
  s = await shell();
  assert(s.panels === ids2.length, `the exit control did not return to the canvas (${s.panels} panels)`);
  assert(await overlayIn(hostId), 'after exiting solo the hidden prompt is still unreachable');
  console.log('  hidden prompt reported, then reached');
  await page.keyboard.press('Escape');   // the picker is open and focused: Escape closes it
  await sleep(350);
  assert(!(await overlayIn(hostId)), 'the picker stayed open — later counts would be wrong');

  // ── 11. SD10/SD18: inert chords, working buttons ─────────────────
  console.log('== 10. Ctrl+W is inert; only pointers leave solo');
  // Canvas view: the chord closes nothing and confirms nothing.
  const rectsNow = await panelRects();
  await chord(['Control'], 'KeyW');
  s = await shell();
  assert(s.panels === ids2.length, `Ctrl+W closed a window in canvas view (${s.panels} panels)`);
  assert((await page.evaluate(() => document.querySelectorAll('.overlay').length)) === 0, 'Ctrl+W opened a confirmation in canvas view');
  assert(JSON.stringify(await panelRects()) === JSON.stringify(rectsNow), 'Ctrl+W moved the layout in canvas view');
  console.log('  canvas view: Ctrl+W did nothing at all');

  // Solo on a window that is NOT the active one. That is the case the menu
  // entry got wrong: `soloTarget` resolves through `activeId`/`planActiveId`,
  // so with a stale-for-the-moment active window the buggy "toggle the target"
  // code moved solo onto a hidden window instead of leaving the view — and the
  // panel count stayed 1, which a weaker assertion would have read as success.
  const activeThen = await page.evaluate(() => {
    const p = document.querySelector('.session-panel-active');
    const all = [...document.querySelectorAll('.session-panel')];
    return { active: p ? p.getAttribute('data-session') : null, order: all.map(x => x.getAttribute('data-session')) };
  });
  assert(activeThen.active, 'no active window to build the premise on');
  const soloChoice = activeThen.order.find(id => id !== activeThen.active);
  assert(soloChoice, 'need a second, non-active window');
  // The ⤢ button of a non-active panel can be under another window, so click
  // it through the DOM; the premise itself is read back below, not assumed.
  assert(await clickEl(`.session-panel[data-session="${soloChoice}"] .session-bar-solo`), 'no solo button to enter solo');
  s = await shell();
  assert(s.panels === 1, 'setup: not solo');
  const premise = await page.evaluate(solo => {
    const shown = document.querySelector('.session-panel');
    const active = document.querySelector('.session-panel-active');
    return {
      soloPanel: shown ? shown.getAttribute('data-session') : null,
      activePanel: active ? active.getAttribute('data-session') : null,
    };
  }, soloChoice);
  // Only ONE panel is rendered, so the active class is on it or absent; the
  // real check is that the ACTIVE session (model-side) is a different window,
  // which the menu cannot see but resolves. Assert what is observable: the
  // hidden set is non-empty and the active id was not the solo one before.
  assert(premise.soloPanel === soloChoice, `solo is on ${premise.soloPanel}, expected ${soloChoice}`);
  assert(activeThen.order.length >= 2, 'premise needs the other window to exist');
  console.log(`  solo is on ${soloChoice}; the ACTIVE window ${activeThen.active} is hidden behind it`);
  assert(await clickEl('.session-bar-menu'), 'the ⋯ button did not open the menu in solo');
  assert(await hasEl('.global-menu-panel'), 'the ⋯ button did not open the menu');
  assert(await clickMenuItem('Exit solo'), 'the menu lost its Exit solo item');
  s = await shell();
  assert(s.panels === ids2.length,
    `the menu's Exit solo did not leave the view (${s.panels} panels) — it re-resolved a target and moved solo onto the hidden ${activeThen.active}`);
  assert(JSON.stringify(await panelRects()) === JSON.stringify(rectsNow), 'a pointer exit changed the stored rects');
  console.log('  both pointer controls leave solo, and nothing else does');

  await shot('11-final.png');

  // ── 12. SD9 from INSIDE solo: the window can still die, and solo goes ─
  // The ✕ is gone in solo (SD19), but solo must still not outlive its window:
  // the delete that reaches it is the Session Manager's, which SD11 keeps
  // reachable through the ⋯ button. This is the only remaining path from a
  // solo window to a closed window, so it is the only one SD9 can be shown on.
  console.log('== 11. deleting the solo session from the Session Manager exits solo (SD9)');
  const ids3 = Object.keys(await panelRects());
  assert(ids3.length >= 2, `setup: need two windows, got ${ids3.length}`);
  const victim = ids3[ids3.length - 1];
  assert(await clickEl(`.session-panel[data-session="${victim}"] .session-bar-solo`), 'no solo button to enter solo');
  assert((await shell()).panels === 1, 'setup: not solo');
  assert(!(await hasEl('.session-bar-close')), 'the solo bar grew a ✕ after all (SD19)');
  assert(await clickEl('.session-bar-menu'), 'the ⋯ button did not open the menu');
  assert(await clickMenuItem('Session Manager'), 'the global menu lost its Session Manager item');
  await waitFor('.overlay .sel-page-item');
  const deleted = await page.evaluate((id) => {
    const rows = [...document.querySelectorAll('.sel-page-item')];
    const row = rows.find(r => (r.querySelector('.sel-page-item-name')?.textContent || '').trim() === id.slice(0, 8));
    const btn = row && [...row.querySelectorAll('button')].find(b => (b.textContent || '').includes('Delete'));
    if (!btn) return false;
    btn.click();
    return true;
  }, victim);
  assert(deleted, `the Session Manager has no Delete button for the solo session ${victim}`);
  await sleep(1200);
  s = await shell();
  assert(s.panels === ids3.length - 1,
    `deleting the solo window left ${s.panels} panels, expected ${ids3.length - 1}`);
  assert(!/main-content-solo/.test(s.cls), 'solo outlived its window (SD9)');
  console.log(`  the solo window died with no ✕ involved, and solo went with it — ${s.panels} panels left`);
  await shot('12-deleted-in-solo.png');
  console.log('ALL PASS');
} catch (err) {
  console.error('E2E FAILED:', err.message);
  try { await page.screenshot({ path: path.join(artifacts, 'failure.png') }); } catch {}
  process.exitCode = 1;
} finally {
  if (browser) await browser.close();
  cleanup();
}

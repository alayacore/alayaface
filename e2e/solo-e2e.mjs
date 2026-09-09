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
let server = null;

// Spawned through a function because §12 restarts it: F3 is about the file
// surviving a backend, so the SAME HOME has to come back on the SAME port with a
// new process holding none of the old one's state.
const startServer = () => {
  const s = spawn(serverBin, ['--addr', `127.0.0.1:${port}`, '--static', '../src-elm', '--alayacore-bin', fakecore], {
    cwd: SRCGO,
    env: { ...process.env, HOME: home },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  s.stderr.on('data', d => { const t = String(d); if (!t.includes('[tlv]') && !t.includes('[rpc]')) process.stdout.write('[srv!] ' + t); });
  server = s;
  return s;
};
startServer();

const waitExit = (s, ms) => new Promise((resolve, reject) => {
  const t = setTimeout(() => reject(new Error('server did not exit within ' + ms + 'ms')), ms);
  s.on('exit', () => { clearTimeout(t); resolve(); });
});

// Read a config file back through the RPC rather than off the disk: the client
// talks to the backend, so that is the path a user's layout actually takes — and
// it proves the value went through the two backends' shape validation instead of
// being a file the client happens to have written to somewhere else.
const rpc = async (cmd, args) => {
  const res = await fetch(`http://127.0.0.1:${port}/rpc/${cmd}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(args || {}),
  });
  const body = await res.text();
  if (!res.ok) throw new Error(`${cmd} → HTTP ${res.status}: ${body}`);
  return body ? JSON.parse(body) : null;
};

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

  // ── 1. three windows on the board ───────────────────────────────
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

  // ── 2. ⤢ — one window, the viewport, nothing else ────────────────
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

  // CONTENT SPANS THE WINDOW (user decision, 2026-09): nothing inside a
  // window is capped to a viewport-derived reading column, and a block is
  // bounded by a top and a bottom rule only. Solo is where this is loudest —
  // the window IS the 1440px viewport, so the old 864px cap would show up as
  // a strip of chat floating in the middle of the screen.
  const span = await page.evaluate(() => {
    const px = el => (el ? parseFloat(getComputedStyle(el).width) : null);
    const left = sel => {
      const el = document.querySelector(sel);
      return el ? +el.getBoundingClientRect().left.toFixed(1) : null;
    };
    const panel = document.querySelector('.session-panel');
    const bar = document.querySelector('.session-input-bar');
    const bubble = document.querySelector('.input-bubble');
    const s = bubble ? getComputedStyle(bubble) : null;
    return {
      panel: px(panel),
      bar: px(bar),
      bubble: px(bubble),
      bl: s ? parseFloat(s.borderLeftWidth) : null,
      br: s ? parseFloat(s.borderRightWidth) : null,
      bt: s ? parseFloat(s.borderTopWidth) : null,
      bb: s ? parseFloat(s.borderBottomWidth) : null,
      // One left edge: the block's rule, its text and the footer row under it.
      rule: left('.input-bubble'),
      text: left('.input-text'),
      footer: left('.footer-btn'),
    };
  });
  console.log('  window content:', JSON.stringify(span));
  assert(span.bar !== null && span.bubble !== null, 'the input column is not rendered');
  // panel (1440) − the chat area's 10px padding on each side.
  assert(span.bar >= span.panel - 24 && span.bubble >= span.bar - 2,
    `the input column does not span the window: ${JSON.stringify(span)}`);
  assert(span.bl === 0 && span.br === 0 && span.bt > 0 && span.bb > 0,
    `the input block is not a pair of horizontal rules: ${JSON.stringify(span)}`);
  // The side padding went with the side borders: text sits ON the rule's end,
  // not 14px inside it. (The window's own inset — .chat-area's 10px — stays.)
  assert(span.rule === span.text && span.rule === span.footer,
    `a block's text is indented away from its own rule: ${JSON.stringify(span)}`);
  await shot('02-solo.png');

  // ── 3. gestures refused, and nothing written ─────────────────────
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

  // ── 4. ⤡ restores the board exactly ──────────────────────────────
  console.log('== 4. exit solo via the ⤡ button');
  const b2 = await soloBtn(topId);
  await clickAt(b2.x, b2.y);
  s = await shell();
  assert(s.panels === 3, `exit must bring back 3 panels, got ${s.panels}`);
  assert(s.handles === 24, `handles must come back, got ${s.handles}`);
  assert(!/main-content-solo/.test(s.cls), 'the solo class survived exit');
  assert(JSON.stringify(await panelRects()) === JSON.stringify(before), 'the layout moved across a solo round trip');
  assert(s.transform === shellBefore.transform, 'the canvas transform moved across a solo round trip');
  await shot('04-restored.png');

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

  // ── 5. SD18: the chord enters, and cannot leave ──────────────────
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

  // ── 6. Ctrl+F is still the browser's ─────────────────────────────
  console.log('== 6. Ctrl+F alone stays free');
  await chord(['Control'], 'KeyF');
  assert((await shell()).panels === 3, 'Ctrl+F entered solo (browser find hijacked)');

  // ── 7. the global menu path, both directions ─────────────────────
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

  // ── 8. SD19: solo has no ✕, and closing is a canvas-view act ─────
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

  // ── 9. SD11: a hidden prompt is reported, then reachable ────────
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

  // ── 10. SD10/SD18: inert chords, working buttons ─────────────────
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

  await shot('10-final.png');

  // ── 11. SD9 from INSIDE solo: the window can still die, and solo goes ─
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
  await shot('11-deleted-in-solo.png');

  // ── 12. F3: the board survives a restart (ui.conf) ────────────────
  // Everything above is about what solo LOOKS like; this is about what the
  // layout store REMEMBERS. It is the half of F3 that elm-test cannot see: a
  // real drag has to end up in a real file, that file has to survive the
  // backend dying, and the window has to come back out of it — in the right
  // place, with solo re-attached, and gone again once the session is deleted.
  //
  // Rects are read in CANVAS space (the file's space) by un-projecting through
  // the transform the canvas actually carries: §4b left the board zoomed, and
  // pretending the scale is 1 here would make the numbers agree by accident.
  console.log('== 12. F3: ui.conf remembers the board across a restart');

  const f3CanvasRect = key => page.evaluate(k => {
    const el = document.querySelector(`.session-panel[data-session="${k}"]`);
    const c = document.querySelector('.canvas');
    if (!el || !c) return null;
    const m = new DOMMatrixReadOnly(getComputedStyle(c).transform);
    const r = el.getBoundingClientRect();
    const s = m.a || 1;
    return { x: Math.round((r.x - m.e) / s), y: Math.round((r.y - m.f) / s), w: Math.round(r.width / s), h: Math.round(r.height / s) };
  }, key);

  // Read the file back through the RPC, not off the disk: that is the path the
  // client's own write took, through both backends' shape validation.
  const f3UiConf = async () => {
    for (let i = 0; i < 20; i++) {
      const r = await rpc('get_ui_config', {});
      if (r && r.config) return r.config;
      await sleep(150);
    }
    return null;
  };

  // §11 leaves exactly one window (and the Session Manager it deleted from
  // still open). One window is all this case needs — and it avoids re-entering
  // the menu, whose preset flyout state the previous sections have toggled.
  await page.keyboard.press('Escape');
  await sleep(500);
  const f3Ids = Object.keys(await panelRects());
  assert(f3Ids.length >= 1, `setup: §11 should have left a window on the board, got ${f3Ids.length}`);
  const f3Moved = f3Ids[f3Ids.length - 1];

  // (a) a real pointer drag on the window bar, ended by a real pointerup
  const f3Bar = await page.evaluate(k => {
    const el = document.querySelector(`.session-panel[data-session="${k}"] .session-bar`);
    const r = el.getBoundingClientRect();
    return { x: Math.round(r.x + 60), y: Math.round(r.y + r.height / 2) };
  }, f3Moved);
  const f3Before = await f3CanvasRect(f3Moved);
  await page.mouse.move(f3Bar.x, f3Bar.y);
  await page.mouse.down();
  await page.mouse.move(f3Bar.x + 140, f3Bar.y + 90, { steps: 6 });
  await page.mouse.up();
  await sleep(700);
  const f3After = await f3CanvasRect(f3Moved);
  console.log(`  dragged ${f3Moved.slice(0, 8)}: ${JSON.stringify(f3Before)} -> ${JSON.stringify(f3After)}`);
  // 140×90 SCREEN px is less than that in canvas space at the zoom §4b left
  // behind; the exact delta is not the assertion — that it moved is.
  assert(f3After.x - f3Before.x >= 20 && f3After.y - f3Before.y >= 10,
    `the pointer drag did not move the window: ${JSON.stringify(f3Before)} -> ${JSON.stringify(f3After)}`);

  // (b) the drag END wrote the file — not the frames on the way
  const f3Stored = await f3UiConf();
  console.log('  ui.conf:', JSON.stringify(f3Stored));
  assert(f3Stored && f3Stored.windows && f3Stored.windows[f3Moved], 'the ended drag did not reach ui.conf');
  const f3Entry = f3Stored.windows[f3Moved];
  assert(near(f3Entry.x, f3After.x) && near(f3Entry.y, f3After.y)
    && near(f3Entry.w, f3After.w) && near(f3Entry.h, f3After.h),
    `ui.conf does not describe where the window stopped: stored ${JSON.stringify(f3Entry)}, screen ${JSON.stringify(f3After)}`);
  assert(f3Entry.t > 0, `the stored entry has no touch (${JSON.stringify(f3Entry)}) — eviction cannot order it`);
  assert(f3Entry.w < 1200, 'ui.conf stored the VIEWPORT as the window width: the store read a presentation rect (SD4)');

  // (b2) the WHEEL is stored too — this is the one write path with no end
  // event, so it is the debounce's job (SD16). Solo is not a zoom (it keeps the
  // transform; §4 proved that), so a non-1 scale here is the wheel's doing and
  // nothing else's. Waiting past the idle timer is what makes this a debounce
  // test rather than a race.
  await page.evaluate(() => {
    document.querySelector('#main-content').dispatchEvent(
      new WheelEvent('wheel', { bubbles: true, cancelable: true, deltaY: -500, clientX: 700, clientY: 500 }));
  });
  await sleep(1600);
  const f3Zoomed = await f3UiConf();
  console.log(`  after the wheel: stored canvasScale=${f3Zoomed && f3Zoomed.canvasScale}`);
  assert(f3Zoomed && Math.abs(f3Zoomed.canvasScale - 1) > 0.01,
    `the wheel zoom never reached ui.conf (scale=${f3Zoomed && f3Zoomed.canvasScale}) — either the debounce did not fire or the viewport is not stored`);

  // (c) solo is part of the layout — and so is leaving it
  assert(await clickEl(`.session-panel[data-session="${f3Moved}"] .session-bar-solo`), 'cannot re-enter solo');
  await sleep(600);
  assert(((await f3UiConf()).soloWin || '') === f3Moved, 'entering solo was not written to ui.conf');
  assert(await clickEl('.session-bar-solo'), 'cannot exit solo');
  await sleep(600);
  assert((await f3UiConf()).soloWin == null,
    'leaving solo left the old flag in ui.conf — a stale intent would hijack the next restart');

  // (d) end in solo, so the restart has something to restore
  assert(await clickEl(`.session-panel[data-session="${f3Moved}"] .session-bar-solo`), 'cannot enter solo for the restart');
  await sleep(600);

  // (e) the backend dies; the file does not
  server.kill('SIGTERM');
  await waitExit(server, 15000);
  startServer();
  await waitPort(port, 30000);
  await page.reload({ waitUntil: 'networkidle0' });
  await page.waitForSelector('.main-content', { timeout: 30000 });
  await sleep(1200);
  assert((await shell()).panels === 0, 'a fresh page should start with an empty board');

  // (e2) snapshot the stored viewport BEFORE anything in the new process can
  // rewrite it. elm-test proves the model applies the stored pan+zoom to
  // itself; only a reload proves those numbers survive encode → file → port →
  // decode — the same seam that nearly ate the window width (see the `w < 1200`
  // guard above), so a green rect check would NOT have caught a viewport that
  // never lands. The live half of this comparison is at the end of (f): the
  // `.canvas` layer only exists once a window does (View renders the welcome
  // panel in its place), so there is nothing to measure on an empty board.
  const f3VpStored = await f3UiConf();
  const f3Scale = f3VpStored && f3VpStored.canvasScale;
  const f3Off = (f3VpStored && f3VpStored.canvasOffset) || {};
  console.log(`  stored viewport before restart: scale=${f3Scale} offset=${JSON.stringify(f3Off)}`);
  assert(f3Scale != null, 'ui.conf carries no canvasScale — the writer never stored the viewport');
  assert(Math.abs(f3Scale - 1) > 0.01 || (f3Off.x || 0) !== 0 || (f3Off.y || 0) !== 0,
    `setup: the stored viewport is the default (scale=${f3Scale}, offset=${JSON.stringify(f3Off)}) — the checks in (f) would pass by accident`);

  // (f) reopen the session: it must come back solo, AND at its stored rect
  await openGlobalMenu();
  assert(await clickMenuItem('Session Manager'), 'the Session Manager did not open after the restart');
  await waitFor('.sel-page-item');
  const f3Resumed = await page.evaluate(prefix => {
    const row = [...document.querySelectorAll('.sel-page-item')]
      .find(r => (r.querySelector('.sel-page-item-name')?.textContent || '').includes(prefix));
    const btn = row && [...row.querySelectorAll('button')].find(b => b.textContent.trim() === 'Resume');
    if (!btn) return false;
    btn.click();
    return true;
  }, f3Moved.slice(0, 8));
  assert(f3Resumed, `the restarted backend cannot resume ${f3Moved.slice(0, 8)} from the manager`);
  await waitFor('.session-panel', 30000);
  await sleep(1500);
  const f3Shell = await shell();
  console.log(`  after restart+resume: panels=${f3Shell.panels}, cls=${f3Shell.cls}`);
  assert(/main-content-solo/.test(f3Shell.cls),
    'the solo flag from ui.conf did not re-attach to the reopened window (SD15)');
  assert(await clickEl('.session-bar-solo'), 'cannot exit solo after the restart');
  await sleep(700);
  const f3Restored = await f3CanvasRect(f3Moved);
  console.log(`  restored rect: ${JSON.stringify(f3Restored)} (stored ${JSON.stringify(f3Entry)})`);
  const near3 = (a, b) => Math.abs(a - b) <= 3;
  assert(near3(f3Restored.x, f3Entry.x) && near3(f3Restored.y, f3Entry.y)
    && near3(f3Restored.w, f3Entry.w) && near3(f3Restored.h, f3Entry.h),
    `the reopened window did not come back where the user left it: ${JSON.stringify(f3Restored)} vs ${JSON.stringify(f3Entry)}`);

  // (f2) and the BOARD came back with it: the zoom and pan the file holds are
  // the ones the restarted page paints. Measured after the solo exit above,
  // because solo keeps the transform it was given (§4), so this is still the
  // viewport the old process wrote — not a fit the new one invented.
  const f3VpLive = await page.evaluate(() => {
    const c = document.querySelector('.canvas');
    if (!c) return null;
    const m = new DOMMatrixReadOnly(getComputedStyle(c).transform);
    return { k: m.a, x: m.e, y: m.f };
  });
  console.log(`  live viewport after restart:  ${JSON.stringify(f3VpLive)}`);
  assert(f3VpLive, 'the .canvas layer is gone — the viewport cannot be read');
  assert(Math.abs(f3VpLive.k - f3Scale) < 0.02,
    `the restarted page did not restore the zoom: live scale ${f3VpLive.k} vs stored ${f3Scale}`);
  assert(Math.abs(f3VpLive.x - (f3Off.x || 0)) <= 3 && Math.abs(f3VpLive.y - (f3Off.y || 0)) <= 3,
    `the restarted page did not restore the pan: live ${JSON.stringify(f3VpLive)} vs stored ${JSON.stringify(f3Off)}`);

  // (g) a DELETED session stops being remembered — read back through the RPC
  await openGlobalMenu();
  assert(await clickMenuItem('Session Manager'), 'the Session Manager did not reopen');
  await waitFor('.sel-page-item');
  const f3Deleted = await page.evaluate(prefix => {
    const row = [...document.querySelectorAll('.sel-page-item')]
      .find(r => (r.querySelector('.sel-page-item-name')?.textContent || '').includes(prefix));
    const btn = row && [...row.querySelectorAll('button')].find(b => (b.textContent || '').includes('Delete'));
    if (!btn) return false;
    btn.click();
    return true;
  }, f3Moved.slice(0, 8));
  assert(f3Deleted, 'no Delete button for the restarted session in the manager');
  await sleep(1500);
  const f3AfterDelete = await f3UiConf();
  const f3Left = Object.keys((f3AfterDelete && f3AfterDelete.windows) || {});
  console.log(`  ui.conf after delete: ${f3Left.length} entries, the deleted key present=${f3Left.includes(f3Moved)}`);
  assert(!f3Left.includes(f3Moved),
    'a deleted session is still in ui.conf: its identity is gone for good, so its rect must be pruned (SD15)');
  console.log('  the board survived the backend, and only the board that still exists did');
  await shot('12-layout-after-restart.png');

  console.log('ALL PASS');
} catch (err) {
  console.error('E2E FAILED:', err.message);
  try { await page.screenshot({ path: path.join(artifacts, 'failure.png') }); } catch {}
  process.exitCode = 1;
} finally {
  if (browser) await browser.close();
  cleanup();
}

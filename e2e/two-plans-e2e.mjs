#!/usr/bin/env node
// Two-plans-in-one-session E2E — regression for the user-reported bug:
// "same session has plans A and B; re-running B replaces what follows B,
// but A's result is appended to the very end instead of replacing what
// follows A".
//
// Flow:
//   1. session S (plan mode) → "Create a plan Alpha" → plan A (planIndex 1)
//      — top-level plans WAIT for the user's Run click, so A sits
//        NotStarted while the session continues.
//   2. S → "Create a plan Beta" → plan B (planIndex 2) auto-creates.
//   3. Run B → B completes → its [Plan Result] lands in S.
//   4. Open A (its [Plan: …] status-bar link is FIRST — A's plan JSON
//      comes before B's) → Run A.
//      P39/D8: A never completed — its anchor is its CREATION point, and
//      B's plan/result follow it, so the confirmation overlay MUST
//      appear ("truncate … N messages") — the pre-fix behavior ran
//      straight through and appended A's result to the very end.
//   5. Confirm → A completes → assertions:
//        * exactly ONE [Plan Result] in S — A's (B's was truncated away,
//          together with B's plan JSON);
//        * A's result carries the [Plan: e2e-demo-…] link;
//        * the confirm overlay was actually shown (regression hook).
//
// Screenshots land in the artifact dir; ALL PASS printed on success.

import puppeteer from 'puppeteer-core';
import { execSync, spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, writeFileSync, rmSync, readdirSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import net from 'node:net';

const ROOT = path.resolve(import.meta.dirname, '..');
const CHROME = '/usr/bin/google-chrome';
const E2E_TIMEOUT = 120000;

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
        if (Date.now() > deadline) reject(new Error('server port timeout'));
        else setTimeout(tick, 250);
      });
    };
    tick();
  });
}

const tmp = mkdtempSync(path.join(tmpdir(), 'alayaface-two-plans-e2e-'));
const home = path.join(tmp, 'home');
const artifacts = path.join(tmp, 'shots');
const SRCGO = path.join(ROOT, 'src-go');
execSync(`mkdir -p "${artifacts}" "${home}"`);
// Clean shared markers; pre-seed the hang-once marker so B's t3 (and
// later A's t3) succeed on the first try (no hang wait). The fail-once
// marker stays ABSENT: B's t2 fails once then retries; A's t2 sees the
// marker and succeeds immediately (fast second run).
execSync('rm -f /tmp/alayaface-fakecore-fail-once-*.marker /tmp/alayaface-fakecore-hang-once-*.marker /tmp/alayaface-fakecore-version.marker');
{
  const t3Prompt = 'review the draft and fix any issues (hang-once marker)';
  const h = createHash('sha256').update(t3Prompt).digest('hex').slice(0, 16);
  writeFileSync(path.join(tmpdir(), `alayaface-fakecore-hang-once-${h}.marker`), 'hung-once');
}
console.log('artifacts:', tmp);

// ── 1. build binaries ───────────────────────────────────────────────
const fakecore = path.join(tmp, 'fakecore');
const serverBin = path.join(tmp, 'alayaface-server');
execSync('go build -o "' + fakecore + '" ./internal/fakecore', { cwd: SRCGO, stdio: 'inherit' });
execSync('go build -o "' + serverBin + '" ./cmd/alayaface-server', { cwd: SRCGO, stdio: 'inherit' });

// ── 2. start Go backend (fresh HOME) ────────────────────────────────
const port = await freePort();
const base = `http://127.0.0.1:${port}`;
const srv = spawn(serverBin, ['--addr', `127.0.0.1:${port}`, '--static', '../src-elm', '--alayacore-bin', fakecore], {
  cwd: SRCGO,
  env: { ...process.env, HOME: home },
  stdio: ['ignore', 'pipe', 'pipe'],
});
let srvOut = '';
srv.stdout.on('data', d => { srvOut += d; process.stdout.write('[srv!] ' + d); });
srv.stderr.on('data', d => process.stdout.write('[srv-err] ' + d));
function killServer() {
  try { srv.kill('SIGTERM'); } catch { /* already gone */ }
}
function onSignal(sig) {
  killServer();
  process.exit(0);
}
process.on('SIGINT', () => onSignal('SIGINT'));
process.on('SIGTERM', () => onSignal('SIGTERM'));
await waitPort(port, 30000);
console.log('backend up on', base);

async function shot(page, name) {
  try { await page.screenshot({ path: path.join(artifacts, name) }); } catch { /* ignore */ }
}

let browser = null;
let page = null;
try {
  // ── 3. Chrome headless ────────────────────────────────────────────
  browser = await puppeteer.launch({
    executablePath: CHROME,
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu', '--window-size=1440,920'],
  });
  page = await browser.newPage();
  await page.setViewport({ width: 1440, height: 920 });
  page.on('pageerror', e => console.log('[pageerror]', e.message));
  page.on('console', m => console.log('[console.' + m.type() + ']', m.text()));

  const waitFor = (sel, ms = 30000) => page.waitForSelector(sel, { timeout: ms });
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  // The global menu is opened by RIGHT-CLICKING the canvas (the fixed
  // ⚙ button was removed).
  const openGlobalMenu = async () => {
    await page.waitForSelector('.main-content', { timeout: 30000 });
    await page.$eval('.main-content', el => el.dispatchEvent(
      new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 30, clientY: 30 })));
    await waitFor('.global-menu-panel');
  };
  const clickByText = async (sel, text) => {
    const handles = await page.$$(sel);
    for (const h of handles) {
      const t = await h.evaluate(el => el.textContent || '');
      if (t.includes(text)) { await h.click(); return true; }
    }
    return false;
  };
  // New Session opens its preset flyout on CLICK: click the item, then
  // click a preset.
  const newSession = async (preset = 'Simple') => {
    const handles = await page.$$('.global-menu-item');
    for (const h of handles) {
      const t = await h.evaluate(el => el.textContent || '');
      if (t.includes('New Session')) {
        await h.click();
        await sleep(200);
        return clickByText('.global-menu-submenu-item', preset);
      }
    }
    return false;
  };

  // ── 4. Session S → plan A ─────────────────────────────────────────
  await page.goto(base + '/', { waitUntil: 'networkidle0', timeout: 30000 });
  await openGlobalMenu();
  assert(await newSession('Simple'), 'New Session → preset submenu');
  await waitFor('.session-panel');
  await sleep(600);

  const sendPrompt = async (text) => {
    // Focus the newest session's input and TYPE for real (Elm's
    // controlled component responds to real keyboard events reliably;
    // programmatic value+input events are flaky under Puppeteer).
    const focused = await page.evaluate(() => {
      const panels = [...document.querySelectorAll('.session-panel')];
      let bestN = -1;
      for (const p of panels) {
        const m = (p.querySelector('.session-bar-title')?.textContent || '').match(/Session (\d+)/);
        const n = m ? parseInt(m[1], 10) : -1;
        if (n > bestN) bestN = n;
      }
      for (const p of panels) {
        const m = (p.querySelector('.session-bar-title')?.textContent || '').match(/Session (\d+)/);
        const n = m ? parseInt(m[1], 10) : -1;
        if (n !== bestN) continue;
        const ta = p.querySelector('textarea.input-text');
        if (ta) { ta.focus(); return true; }
      }
      return false;
    });
    if (!focused) throw new Error('sendPrompt: no input to focus');
    await page.keyboard.type(text, { delay: 5 });
    await sleep(150);
    const clicked = await page.evaluate(() => {
      const p = [...document.querySelectorAll('.session-panel')].find(x => x.querySelector('.send-btn'));
      if (!p) return false;
      const ta = p.querySelector('textarea.input-text');
      if (!ta || !ta.value.trim()) return false;
      const btn = p.querySelector('.send-btn');
      btn.click();
      return true;
    });
    if (!clicked) throw new Error('sendPrompt: no staged text to send: ' + text);
    console.log('[sendPrompt] sent:', text.slice(0, 40));
    await sleep(400);
  };

  // Plan A (planIndex 1) — top-level plans wait for Run.
  await sendPrompt('Create a plan Alpha for the two-plans e2e');
  await page.waitForFunction(() => document.querySelectorAll('.plan-page').length === 1, { timeout: 30000 });
  await sleep(600);
  await shot(page, '01-plan-a-created.png');
  console.log('PASS: plan A auto-created (waiting for Run)');

  // ── 5. Plan B (planIndex 2) → run it to completion ────────────────
  await sendPrompt('Create a plan Beta for the two-plans e2e');
  // fakecore names the SECOND plan "E2E Demo Beta" — wait for its
  // status-bar link to appear (B's plan JSON is in S and the plan
  // window is now B).
  await page.waitForFunction(() => {
    return [...document.querySelectorAll('.plan-offer-btn')].some(e => (e.textContent || '').includes('E2E Demo Beta'));
  }, { timeout: 30000 });
  await sleep(800);
  await shot(page, '02-b-created.png');
  // Click RUN on plan B's own window (data-plan starts with
  // e2e-demo-beta; A's window is e2e-demo-<ts>).
  const runB = await page.evaluate(() => {
    const win = [...document.querySelectorAll('.plan-panel')].find(p =>
      (p.getAttribute('data-plan') || '').startsWith('e2e-demo-beta'));
    const btn = win && win.querySelector('.plan-run-strip button');
    if (btn) { btn.click(); return true; }
    return false;
  });
  assert(runB, 'Run button (plan B window)');
  // P39/D8: while plan B runs, the origin session's input is disabled.
  await sleep(700);
  const disabledDuringB = await page.evaluate(() => {
    const p = [...document.querySelectorAll('.session-panel')].find(x => x.querySelector('.send-btn'));
    const ta = p && p.querySelector('textarea.input-text');
    return ta ? ta.disabled : false;
  });
  assert(disabledDuringB, 'session input disabled while plan B runs');
  console.log('PASS: session input disabled while plan B is running');
  await page.waitForFunction(() => {
    return [...document.querySelectorAll('.plan-offer-btn')].some(e => e.textContent.includes('Completed'));
  }, { timeout: E2E_TIMEOUT });
  await sleep(800);
  await shot(page, '03-b-completed.png');
  // Input must be re-enabled once the plan completed.
  const enabledAfterB = await page.evaluate(() => {
    const p = [...document.querySelectorAll('.session-panel')].find(x => x.querySelector('.send-btn'));
    const ta = p && p.querySelector('textarea.input-text');
    return ta ? !ta.disabled : false;
  });
  assert(enabledAfterB, 'session input re-enabled after plan B completed');
  console.log('PASS: session input re-enabled after plan B completed');
  // User echoes are collapsed by default (Phase 7 "fold" design): the
  // body is empty and the full result is folded into the header's
  // one-line preview (the last line of the message — the plan link
  // [Plan: e2e-demo-beta-…]). Match the preview, not .message-content.
  const msgsB = await page.$$eval('.message-user .msg-preview', els => els.map(e => e.textContent || ''));
  const bResults = msgsB.filter(t => /\[Plan: e2e-demo-beta-\d+\]/.test(t));
  assert(bResults.length === 1,
    'B completed → its [Plan: e2e-demo-beta-…] result is in S, got: ' + JSON.stringify(bResults));
  console.log('PASS: plan B ran to completion, its [Plan Result] is in S');

  // ── 6. Open plan A via its [Plan: …] status-bar link (FIRST one) ──
  const openedA = await page.evaluate(() => {
    const b = [...document.querySelectorAll('button')].find(e => /^\[Plan: /.test((e.textContent || '').trim()));
    if (b) { b.click(); return true; }
    return false;
  });
  assert(openedA, 'plan A status-bar link present');
  await page.waitForFunction(() => document.querySelectorAll('.plan-page').length === 1, { timeout: 10000 });
  await sleep(400);

  // ── 7. Run A → the confirmation overlay MUST appear (P39/D8) ─────
  // Plan A's window: data-plan starts with e2e-demo- but NOT beta.
  const runA = await page.evaluate(() => {
    const win = [...document.querySelectorAll('.plan-panel')].find(p => {
      const d = p.getAttribute('data-plan') || '';
      return d.startsWith('e2e-demo-') && !d.startsWith('e2e-demo-beta');
    });
    const btn = win && win.querySelector('.plan-run-strip button');
    if (btn) { btn.click(); return true; }
    return false;
  });
  assert(runA, 'Run button (plan A window)');
  const confirmShown = await page.waitForSelector('.cascade-page .btn-primary', { timeout: 10000 })
    .then(() => true)
    .catch(() => false);
  assert(confirmShown,
    'plan A (never completed, followed by B) must show the impact-scope confirmation before running');
  await shot(page, '03-confirm-overlay.png');
  await page.evaluate(() => {
    const b = document.querySelector('.cascade-page .btn-primary');
    if (b) b.click();
  });
  console.log('PASS: confirmation overlay shown for plan A (creation-anchor truncation)');

  // ── 8. A completes → assertions ───────────────────────────────────
  // User echoes are collapsed by default (Phase 7 fold design): match
  // the header preview (last line of the message — the plan link).
  await page.waitForFunction(() => {
    const pre = [...document.querySelectorAll('.message-user .msg-preview')].map(e => e.textContent || '');
    return pre.some(t => /\[Plan: e2e-demo-\d+\]/.test(t));
  }, { timeout: E2E_TIMEOUT });
  await sleep(800);
  await shot(page, '04-final.png');

  const pre = await page.$$eval('.message-user .msg-preview', els => els.map(e => e.textContent || ''));
  const results = pre.filter(t => /\[Plan: e2e-demo-\d+\]/.test(t));
  assert(results.length === 1,
    'exactly ONE [Plan Result] remains (A\'s; B\'s was truncated away), got: ' + JSON.stringify(results));
  assert(!/e2e-demo-beta/.test(results[0]),
    "A's [Plan Result] carries the [Plan: e2e-demo-…] link (not Beta), got: " + results[0].slice(0, 120));
  const msgs = await page.$$eval('.message-content', els => els.map(e => e.textContent || ''));
  assert(!msgs.some(t => t.includes('E2E Demo Beta')),
    "plan B's plan JSON + result are gone (truncated at A's creation anchor)");
  console.log('PASS: A\'s [Plan Result] sits after A (B\'s plan/result replaced, not appended past)');

  // Plan windows are gone (A auto-closed on completion; B was closed at
  // confirm).
  const planPages = await page.$$eval('.plan-page', els => els.length);
  assert(planPages === 0, 'no plan windows remain, got: ' + planPages);
  console.log('PASS: plan windows closed after the cascade');

  // ── 9. C-architecture regression: version-isolated plan state.
  //        The Session root (sessions/<rootId>/) holds session.refs.json
  //        (head = V1, versions = [V0, V1]) and objects/ keeps both
  //        worlds: V0 (pre-rerun: A unexecuted, B completed) and V1
  //        (A completed). The OLD world is a VERSION — resume always
  //        restores the CURRENT work copy (head), so the old-world
  //        check reads the version objects on disk (C4 will add UI).
  const sessionsRoot = path.join(home, '.alayaface', 'sessions');
  const objectsRoot = path.join(home, '.alayaface', 'objects');
  let rootSid = null;
  let rootRefs = null;
  for (let tries = 0; tries < 20 && !rootRefs; tries++) {
    await sleep(500);
    const allSids = readdirSync(sessionsRoot).filter(d => !d.endsWith('.tmp'));
    for (const sid of allSids) {
      try {
        const refsPath = path.join(sessionsRoot, sid, 'session.refs.json');
        if (!existsSync(refsPath)) continue;
        const refs = JSON.parse(readFileSync(refsPath, 'utf8'));
        if (refs.head && refs.head !== '' && refs.versions && refs.versions.length >= 2) {
          rootSid = sid;
          rootRefs = refs;
          break;
        }
      } catch (e) { /* not yet */ }
    }
  }
  assert(rootRefs, 'Session root with two versions found on disk');
  const readVersion = h =>
    JSON.parse(readFileSync(path.join(objectsRoot, h, 'content.json'), 'utf8'));
  const v0 = readVersion(rootRefs.versions[0]);
  const v1 = readVersion(rootRefs.versions[rootRefs.versions.length - 1]);
  const planKeys = Object.keys(v0.planViews || {});
  const aKey = planKeys.find(k => /^e2e-demo-/.test(k) && !/beta/.test(k));
  const bKey = planKeys.find(k => /beta/.test(k));
  assert(aKey && bKey, 'V0 planViews has A and B keys, got: ' + JSON.stringify(planKeys));
  const runStatus = rv => (rv === null ? null : (readVersion(rv) || {}).status || '?');
  const a0 = runStatus(v0.planViews[aKey]);
  assert(a0 === null || a0 === 'not_started',
    'V0 world: A unexecuted (null or not_started view), got: ' + a0);
  assert(runStatus(v0.planViews[bKey]) === 'completed',
    'V0 world: B completed, got: ' + runStatus(v0.planViews[bKey]));
  assert(runStatus(v1.planViews[aKey]) === 'completed',
    'V1 world: A completed, got: ' + runStatus(v1.planViews[aKey]));
  console.log('PASS: version isolation on disk — V0 (A unexecuted, B completed) vs V1 (A completed)');

  // ── 10. C4 version browsing UI ────────────────────────────────────
  // Session Manager → Versions (n) → View v0 → read-only message list.
  await openGlobalMenu();
  assert(await clickByText('.global-menu-item', 'Session Manager'), 'Session Manager menu item (versions)');
  await page.waitForSelector('.sel-page-item', { timeout: 10000 });
  const openedVersions = await page.evaluate(() => {
    const items = [...document.querySelectorAll('.sel-page-item')];
    for (const it of items) {
      const btn = [...it.querySelectorAll('button')].find(b => (b.textContent || '').startsWith('Versions ('));
      if (btn) { btn.click(); return btn.textContent; }
    }
    return null;
  });
  assert(openedVersions && parseInt(openedVersions.match(/\d+/)[0], 10) >= 2,
    'Versions button shows the version count, got: ' + openedVersions);
  await page.waitForFunction(() => {
    return [...document.querySelectorAll('.sel-page-item-name')].some(e => /^v\d+$/.test((e.textContent || '').trim()));
  }, { timeout: 10000 });
  const versionNames = await page.$$eval('.sel-page-item-name', els => els.map(e => e.textContent || '').filter(t => /^v\d+$/.test(t.trim())));
  assert(versionNames.length >= 2, 'version list shows v0/v1/…, got: ' + JSON.stringify(versionNames));
  // View the OLDEST version (v0): its messages must show the ORIGINAL
  // world (A + B + B's result), and the plan lines A=not-started etc.
  await page.evaluate(() => {
    const items = [...document.querySelectorAll('.sel-page-item')];
    const it = items.find(x => (x.querySelector('.sel-page-item-name')?.textContent || '').trim() === 'v0');
    const btn = it && [...it.querySelectorAll('button')].find(b => b.textContent.trim() === 'View');
    if (btn) btn.click();
  });
  await page.waitForFunction(() => {
    return document.querySelectorAll('.version-msg').length > 0 ||
           (document.body.innerText || '').includes('Loading version');
  }, { timeout: 10000 });
  await sleep(800);
  const vBody = await page.$$eval('.version-msg-content', els => els.map(e => e.textContent || ''));
  assert(vBody.some(t => t.includes('Create a plan Alpha')), 'v0 shows the ORIGINAL world messages, got: ' + JSON.stringify(vBody.slice(0, 3)));
  const vPlanLines = await page.$$eval('.version-plan-line', els => els.map(e => e.textContent || ''));
  assert(vPlanLines.some(t => t.includes('e2e-demo-beta') && t.includes('completed')),
    'v0 plan line shows B completed, got: ' + JSON.stringify(vPlanLines));
  console.log('PASS: version browsing UI — v0 read-only view shows the old world');

  console.log('\nALL PASS ✅');
  console.log('screenshots:');
  for (const f of readdirSync(artifacts)) console.log('  ' + path.join(artifacts, f));
} catch (err) {
  if (page) {
    await shot(page, 'failure.png').catch(() => {});
    try {
      const txt = await page.evaluate(() => document.body.innerText.slice(0, 3000));
      console.log('[page-text]', txt.replace(/\n+/g, ' | ').slice(0, 2500));
    } catch { /* ignore */ }
  }
  console.error('E2E FAILED:', err.message);
  process.exitCode = 1;
} finally {
  killServer();
  if (browser) await browser.close().catch(() => {});
  if (!process.env.ALAYAFACE_KEEP_ARTIFACTS) {
    try { rmSync(tmp, { recursive: true, force: true }); } catch { /* already gone */ }
  } else {
    console.log('artifacts kept at:', tmp);
  }
}

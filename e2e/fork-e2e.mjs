#!/usr/bin/env node
// Cascade-fork E2E — the FULL re-run cascade with a truncating fork.
//
//   session S (plan mode) → "give me a plan" → plan P1 auto-creates
//   → Run → completed → [Plan Result] inserted into S
//   → RE-RUN with the version marker (fakecore replies differ, so the
//     cascade gate passes) → S is FORKED to S' (session.alaya truncated
//     up to the old [Plan Result], then replayed by the forked process)
//
// Assertions (C2b — the fork replaces the Session's WORK COPY, not its
// identity):
//   * the replayed plan message in the fork window binds the status bar
//     to "[Plan: e2e-demo-…] E2E Demo · Completed" — NOT the generic
//     "Open plan" fallback (the original bug);
//   * the [Plan Result] message carries the [Plan: …] link with the
//     (v2) summary;
//   * no duplicate plan window / plan file (replay suppression);
//   * ownership on disk: the Session root (sessions/<root>/) holds
//     session.refs.json with head=V1 and workCopy=<fork dir>; the work
//     copy dir is NOT a session (no refs.json); NO session.meta.json
//     (lineage deleted, C2b-7);
//   * the SAME session window stays (window key = Session.id — no new
//     window, position preserved);
//   * restart: the manager lists ONLY the Session root; resuming it
//     restores the WORK COPY (refs.workCopy) and rebinds;
//   * chained fork: refs.workCopy advances to the second fork and the
//     previous work copy dir is deleted (work copy lifecycle).

import puppeteer from 'puppeteer-core';
import { execSync, spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, writeFileSync, existsSync, readdirSync, readFileSync, rmSync } from 'node:fs';
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

const tmp = mkdtempSync(path.join(tmpdir(), 'alayaface-fork-e2e-'));
const home = path.join(tmp, 'home');
const artifacts = path.join(tmp, 'shots');
const SRCGO = path.join(ROOT, 'src-go');
execSync(`mkdir -p "${artifacts}" "${home}"`);
// Shared markers: clean everything so the FIRST run exercises the
// fail-once path; the hang marker is pre-seeded (R1: no task timeouts).
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

const port = await freePort();
const base = `http://127.0.0.1:${port}`;

// ── 2. start Go backend (fresh HOME) ────────────────────────────────
const server = spawn(serverBin, ['--addr', `127.0.0.1:${port}`, '--static', '../src-elm', '--alayacore-bin', fakecore], {
  cwd: SRCGO,
  env: { ...process.env, HOME: home },
  stdio: ['ignore', 'pipe', 'pipe'],
});
server.stdout.on('data', d => process.stdout.write('[srv] ' + d));
server.stderr.on('data', d => process.stdout.write('[srv!] ' + d));

let browser;
const shots = [];
async function shot(page, name) {
  const p = path.join(artifacts, name);
  await page.screenshot({ path: p });
  shots.push(p);
}

const KEEP_ARTIFACTS = process.env.ALAYAFACE_KEEP_ARTIFACTS === '1';
function removeTmp() {
  if (KEEP_ARTIFACTS) return;
  try { rmSync(tmp, { recursive: true, force: true }); } catch {}
}
function killServer() {
  try { server.kill('SIGTERM'); } catch {}
}
let exiting = false;
function onSignal(sig) {
  if (exiting) return;
  exiting = true;
  killServer();
  removeTmp();
  process.exit(sig === 'SIGINT' ? 130 : 143);
}
process.on('SIGINT', () => onSignal('SIGINT'));
process.on('SIGTERM', () => onSignal('SIGTERM'));
process.on('SIGHUP', () => onSignal('SIGHUP'));

try {
  await waitPort(port, 30000);

  // ── 3. Chrome headless ────────────────────────────────────────────
  browser = await puppeteer.launch({
    executablePath: CHROME,
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu', '--window-size=1440,920'],
  });
  const page = await browser.newPage();
  await page.setViewport({ width: 1440, height: 920 });
  page.on('pageerror', e => console.log('[pageerror]', e.message));
  page.on('console', m => console.log('[console.' + m.type() + ']', m.text()));
  page.on('response', async r => {
    if (r.status() >= 400) {
      const body = await r.text().catch(() => '');
      console.log('[http ' + r.status() + ']', r.url(), body.slice(0, 300));
    }
  });

  const waitFor = (sel, ms = 30000) => page.waitForSelector(sel, { timeout: ms, visible: true });
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  // The global menu is opened by RIGHT-CLICKING the canvas (the fixed
  // ⚙ button was removed) and closed by clicking outside the menu.
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
  // New Session is a hover flyout: hover the item, then click a preset.
  const newSession = async (preset = 'Simple') => {
    const handles = await page.$$('.global-menu-item');
    for (const h of handles) {
      const t = await h.evaluate(el => el.textContent || '');
      if (t.includes('New Session')) {
        const box = await h.boundingBox();
        await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
        await sleep(200);
        return clickByText('.global-menu-submenu-item', preset);
      }
    }
    return false;
  };

  // ── 4. Session S → plan offer ─────────────────────────────────────
  const reopenPlanViaStatusBar = () => {
    return page.evaluate(() => {
      const b = [...document.querySelectorAll('button')].find(e => /^\[Plan: /.test((e.textContent || '').trim()));
      if (b) b.click();
    }).then(() => page.waitForFunction(() => document.querySelectorAll('.plan-page').length === 1, { timeout: 10000 }))
      .then(() => sleep(400));
  };
  await page.goto(base + '/', { waitUntil: 'networkidle0', timeout: 30000 });
  await openGlobalMenu();
  assert(await newSession('Simple'), 'New Session → preset submenu');
  await waitFor('.session-panel');
  await sleep(600);

  await page.evaluate(() => {
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
      if (ta) {
        ta.value = 'Create a demo plan for e2e';
        ta.dispatchEvent(new Event('input', { bubbles: true }));
      }
      const btn = p.querySelector('.send-btn');
      if (btn) btn.click();
    }
  });
  // Plan auto-creates (R2).
  await page.waitForFunction(() => document.querySelectorAll('.plan-page').length === 1, { timeout: 30000 });
  await sleep(600);
  await shot(page, '01-plan-created.png');
  console.log('PASS: plan auto-created from session S');

  // ── 5. First run → Completed + [Plan Result] in S ────────────────
  // The plan window width must match the session window width.
  const winWidths = await page.evaluate(() => {
    const sp = document.querySelector('.session-panel');
    const pp = document.querySelector('.plan-panel');
    const w = el => (el ? getComputedStyle(el).width : null);
    return { s: w(sp), p: w(pp) };
  });
  assert(winWidths.s && winWidths.p && winWidths.s === winWidths.p,
    'plan window width matches the session window width, got: ' + JSON.stringify(winWidths));
  console.log('PASS: plan window width matches the session window (' + winWidths.p + ')');
  assert(await clickByText('button.plan-strip-btn', 'Run'), 'Run button');
  await page.waitForFunction(() => {
    return [...document.querySelectorAll('.plan-offer-btn')].some(e => e.textContent.includes('Completed'));
  }, { timeout: E2E_TIMEOUT });
  await sleep(800);
  await shot(page, '02-first-completed.png');
  const fb1 = await page.$$eval('.message-content', els => els.map(e => e.textContent || ''));
  assert(fb1.some(t => t.includes('[Plan Result]')), 'first-run [Plan Result] present in S');
  assert(fb1.some(t => t.includes('findings v2')) === false, 'first run must NOT carry the v2 suffix');
  const planFilesBefore = findPlanDirs().length;
  assert(planFilesBefore === 1, 'exactly one plan dir before re-run, got: ' + planFilesBefore);
  console.log('PASS: first run completed, [Plan Result] in S (no v2)');

  // ── 6. RE-RUN with version marker → gate passes → fork ──────────
  // Remember the ORIGINAL session window's spot: the fork replacement
  // (S') must open at the SAME position (P39/D8 no window jump).
  const sPosBefore = await page.evaluate(() => {
    const p = document.querySelector('.session-panel');
    const cs = getComputedStyle(p);
    return { left: cs.left, top: cs.top, width: cs.width, height: cs.height };
  });
  writeFileSync(path.join(tmpdir(), 'alayaface-fakecore-version.marker'), 'v2');
  await reopenPlanViaStatusBar();
  assert(await clickByText('button.plan-strip-btn', 'Run'), 're-Run button');
  // Impact-scope confirmation (the old result sits in S).
  await page.waitForSelector('.cascade-page .confirm-page-btn-allow', { timeout: 10000 }).catch(() => {});
  await page.evaluate(() => {
    const b = document.querySelector('.cascade-page .confirm-page-btn-allow');
    if (b) b.click();
  });

  // The cascade completes → fork → the SAME window takes over the fork
  // world (work copy): replays the truncated history + receives the v2
  // [Plan Result]. Wait for the v2 feedback message AND a status bar
  // that binds (no "Open plan" fallback — the original bug).
  await page.waitForFunction(() => {
    const bars = [...document.querySelectorAll('.plan-offer-btn')].map(e => e.textContent || '');
    if (bars.length === 0) return false;
    if (bars.some(t => t.includes('Open plan'))) return false;
    if (!bars.some(t => t.includes('Completed'))) return false;
    const msgs = [...document.querySelectorAll('.message-content')].map(e => e.textContent || '');
    return msgs.some(t => t.includes('[Plan Result]') && t.includes('findings v2'));
  }, { timeout: E2E_TIMEOUT });
  await sleep(800);
  await shot(page, '03-forked-v2.png');

  // ── 7. Assertions ─────────────────────────────────────────────────
  // a) Status bar in the fork session binds to the plan (the user bug).
  const bars = await page.$$eval('.plan-offer-btn', els => els.map(e => e.textContent || ''));
  assert(bars.length > 0, 'status bar present in the fork session, got: ' + JSON.stringify(bars));
  assert(bars.every(t => /^\[Plan: /.test(t.trim())), 'every status bar binds a plan (no "Open plan" fallback), got: ' + JSON.stringify(bars));
  assert(bars.some(t => t.includes('E2E Demo') && t.includes('Completed')),
    'status bar shows [Plan: …] E2E Demo · Completed, got: ' + JSON.stringify(bars));
  console.log('PASS: fork session status bar binds [Plan: …] E2E Demo · Completed (no "Open plan" fallback)');

  // b) The [Plan Result] link + (v2) summary arrived in the fork.
  const msgs = await page.$$eval('.message-content', els => els.map(e => e.textContent || ''));
  const v2result = msgs.filter(t => t.includes('[Plan Result]') && t.includes('findings v2'));
  assert(v2result.length >= 1, 'v2 [Plan Result] present, got: ' + JSON.stringify(msgs.slice(-3)));
  assert(v2result.some(t => t.includes('[Plan: e2e-demo-')), 'v2 [Plan Result] carries the [Plan: …] link');
  console.log('PASS: v2 [Plan Result] with the [Plan: …] link in the fork session');

  // c) No duplicate plan (replay suppression) and the plan auto-closed.
  const planPages = await page.$$eval('.plan-page', els => els.length);
  assert(planPages === 0, 'completed plan window auto-closed, got: ' + planPages);
  const planFilesAfter = findPlanDirs().length;
  assert(planFilesAfter === 1, 'replayed plan message did NOT create a duplicate plan, got: ' + planFilesAfter);
  console.log('PASS: no duplicate plan window/file after fork replay');

  // d) C2b ownership: the Session root (sessions/<rootId>/) holds
  //    session.refs.json with `workCopy` = the fork dir; the work copy
  //    dir (sessions/<forkId>/) is NOT a session (no refs.json); the
  //    lineage meta (session.meta.json) is GONE (C2b-7).
  const sessionsRoot = path.join(home, '.alayaface', 'sessions');
  const sessionDirs = readdirSync(sessionsRoot).filter(d => !d.endsWith('.tmp'));
  let rootRefs = null;
  for (let tries = 0; tries < 20 && !rootRefs; tries++) {
    await sleep(500);
    for (const sid of sessionDirs) {
      const f = path.join(sessionsRoot, sid, 'session.refs.json');
      if (existsSync(f)) { rootRefs = { sid, refs: JSON.parse(readFileSync(f, 'utf8')) }; break; }
    }
  }
  assert(rootRefs, 'Session root (session.refs.json) found on disk');
  assert(rootRefs.refs.head && rootRefs.refs.head !== '', 'refs.head set (V1 frozen), got: ' + JSON.stringify(rootRefs.refs));
  assert(typeof rootRefs.refs.workCopy === 'string' && rootRefs.refs.workCopy.length > 0,
    'refs.workCopy records the fork dir, got: ' + JSON.stringify(rootRefs.refs));
  assert(!existsSync(path.join(sessionsRoot, rootRefs.sid, 'session.meta.json')),
    'no session.meta.json (lineage deleted, C2b-7)');
  const rootSid = rootRefs.sid;
  const forkSid = rootRefs.refs.workCopy;
  assert(existsSync(path.join(sessionsRoot, forkSid, 'session.alaya')), 'work copy dir has session.alaya');
  assert(!existsSync(path.join(sessionsRoot, forkSid, 'session.refs.json')),
    'work copy dir is NOT a Session (no refs.json)');
  console.log('PASS: ownership on disk — root=' + rootSid + ', refs.workCopy=' + forkSid + ' (fork dir), no lineage meta');

  // e) The SAME window stays (window key = Session.id — the fork only
  //    replaced the work copy), so its position is trivially preserved.
  const panelCount = await page.$$eval('.session-panel:not(.plan-panel)', els => els.length);
  assert(panelCount === 1, 'exactly ONE session window (no new window for the fork), got: ' + panelCount);
  const sPosAfter = await page.evaluate(() => {
    const p = document.querySelector('.session-panel:not(.plan-panel)');
    const cs = getComputedStyle(p);
    return { left: cs.left, top: cs.top, width: cs.width, height: cs.height };
  });
  assert(JSON.stringify(sPosAfter) === JSON.stringify(sPosBefore),
    'session window kept its position (same window), got before=' +
      JSON.stringify(sPosBefore) + ' after=' + JSON.stringify(sPosAfter));
  console.log('PASS: same window kept its position (no window jump)');
  await shot(page, '04-final.png');
  console.log('PASS: work copy takeover — the same window now shows the fork world');

  // ── 8. RESTART consistency (C2b) ─────────────────────────────────
  // Page refresh: close_all_sessions gracefully saves every session
  // (fakecore's save KEEPS the fork's truncated history), then the
  // scan rebuilds planMetas + sessionRefs from session.refs.json (the
  // manager lists ONLY Session roots — the work copy dir is hidden).
  // Resume the Session ROOT → the backend restores refs.workCopy dir
  // (the fork's truncated history) → replays → the replayed plan
  // message binds by Session.id (no "Open plan").
  await page.reload({ waitUntil: 'networkidle0', timeout: 30000 });
  await sleep(2000); // close_all_sessions + scan settle
  await openGlobalMenu();
  assert(await clickByText('.global-menu-item', 'Session Manager'), 'Session Manager menu item (refresh)');
  // The overlay list may be considered non-visible by Puppeteer (scroll
  // container); wait for presence, not visibility.
  await page.waitForSelector('.sel-page-item', { timeout: 10000 });
  // The manager must show ONLY the Session root (never the work copy).
  const managerNames = await page.$$eval('.sel-page-item-name', els => els.map(e => e.textContent || ''));
  assert(managerNames.length === 1, 'manager lists exactly one Session (the root), got: ' + JSON.stringify(managerNames));
  assert(managerNames[0].includes(rootSid.slice(0, 8)),
    'manager shows the root, got: ' + JSON.stringify(managerNames));
  const resumedRoot = await page.evaluate((fid) => {
    const items = [...document.querySelectorAll('.sel-page-item')];
    for (const it of items) {
      const name = it.querySelector('.sel-page-item-name')?.textContent || '';
      const btn = [...it.querySelectorAll('button')].find(b => b.textContent.trim() === 'Resume');
      if (name === fid.slice(0, 8) && btn && !btn.disabled) { btn.click(); return true; }
    }
    return false;
  }, rootSid);
  assert(resumedRoot, 'Session root Resume clickable after refresh (restores the work copy)');
  // The resumed session replays the work copy's truncated history; the
  // replayed plan message must bind by Session.id.
  await page.waitForFunction(() => {
    const bars = [...document.querySelectorAll('.plan-offer-btn')].map(e => e.textContent || '');
    if (bars.length === 0) return false;
    if (bars.some(t => t.includes('Open plan'))) return false;
    return bars.some(t => t.includes('E2E Demo') && t.includes('Completed'));
  }, { timeout: 30000 });
  await sleep(600);
  const planFilesAfterRestart = findPlanDirs().length;
  assert(planFilesAfterRestart === 1, 'no duplicate plan after restart+resume, got: ' + planFilesAfterRestart);
  await shot(page, '05-after-restart.png');
  console.log('PASS: after refresh, resuming the root restores the work copy and rebinds the status bar (no duplicate plan)');

  // ── 9. CHAINED fork: re-run the plan AGAIN on the resumed head (S') ─
  // Marker content → "v3": the new run's summaries differ from v2, so
  // the cascade gate passes again and S' is forked to S'' — the lineage
  // chain grows S → S' → S''. The plan's status bar lives in the
  // resumed S' window.
  writeFileSync(path.join(tmpdir(), 'alayaface-fakecore-version.marker'), 'v3');
  await reopenPlanViaStatusBar();
  assert(await clickByText('button.plan-strip-btn', 'Run'), 'chained re-Run button');
  await page.waitForSelector('.cascade-page .confirm-page-btn-allow', { timeout: 10000 }).catch(() => {});
  await page.evaluate(() => {
    const b = document.querySelector('.cascade-page .confirm-page-btn-allow');
    if (b) b.click();
  });
  await page.waitForFunction(() => {
    const bars = [...document.querySelectorAll('.plan-offer-btn')].map(e => e.textContent || '');
    if (bars.length === 0) return false;
    if (bars.some(t => t.includes('Open plan'))) return false;
    if (!bars.some(t => t.includes('Completed'))) return false;
    const msgs = [...document.querySelectorAll('.message-content')].map(e => e.textContent || '');
    return msgs.some(t => t.includes('[Plan Result]') && t.includes('findings v3'));
  }, { timeout: E2E_TIMEOUT });
  await sleep(800);
  await shot(page, '06-chained-fork.png');

  // Work-copy lifecycle: refs.workCopy advanced to the SECOND fork; the
  // FIRST fork's dir was deleted (delayed until the old process's
  // graceful close finishes — old work copy lifecycle).
  const sessionsRoot2 = path.join(home, '.alayaface', 'sessions');
  const roots2 = [];
  for (const sid of readdirSync(sessionsRoot2).filter(d => !d.endsWith('.tmp'))) {
    const f = path.join(sessionsRoot2, sid, 'session.refs.json');
    if (existsSync(f)) roots2.push({ sid, refs: JSON.parse(readFileSync(f, 'utf8')) });
  }
  assert(roots2.length === 1, 'exactly ONE Session root after chained fork, got: ' + JSON.stringify(roots2));
  const root2 = roots2[0];
  const fork2Sid = root2.refs.workCopy;
  assert(fork2Sid && fork2Sid !== forkSid, 'work copy advanced to the second fork, got: ' + JSON.stringify(roots2));
  // The old work copy dir is removed AFTER the old process's graceful
  // close (delayed delete) — poll for it.
  let oldDirGone = false;
  for (let tries = 0; tries < 20 && !oldDirGone; tries++) {
    await sleep(400);
    oldDirGone = !existsSync(path.join(sessionsRoot2, forkSid));
  }
  assert(oldDirGone, 'previous work copy dir deleted after the chained fork, got sids: ' +
    JSON.stringify(readdirSync(sessionsRoot2).filter(d => !d.endsWith('.tmp'))));
  assert(existsSync(path.join(sessionsRoot2, fork2Sid, 'session.alaya')), 'new work copy dir present');
  console.log('PASS: chained fork — root=' + root2.sid + ' refs.workCopy=' + fork2Sid + ' (old work copy deleted)');

  // ── 10. RESTART with a chained work copy ──────────────────────────
  // Resuming the Session root restores the LATEST work copy (fork2).
  await page.reload({ waitUntil: 'networkidle0', timeout: 30000 });
  await sleep(2000); // close_all_sessions + scan settle
  await openGlobalMenu();
  assert(await clickByText('.global-menu-item', 'Session Manager'), 'Session Manager menu item (chained refresh)');
  await page.waitForSelector('.sel-page-item', { timeout: 10000 });
  const managerNames2 = await page.$$eval('.sel-page-item-name', els => els.map(e => e.textContent || ''));
  assert(managerNames2.length === 1, 'manager lists exactly one Session (root), got: ' + JSON.stringify(managerNames2));
  const resumedHead = await page.evaluate((fid) => {
    const items = [...document.querySelectorAll('.sel-page-item')];
    for (const it of items) {
      const name = it.querySelector('.sel-page-item-name')?.textContent || '';
      const btn = [...it.querySelectorAll('button')].find(b => b.textContent.trim() === 'Resume');
      if (name === fid.slice(0, 8) && btn && !btn.disabled) { btn.click(); return true; }
    }
    return false;
  }, root2.sid);
  assert(resumedHead, 'Session root Resume clickable after chained refresh (restores fork2)');
  await page.waitForFunction(() => {
    const bars = [...document.querySelectorAll('.plan-offer-btn')].map(e => e.textContent || '');
    if (bars.length === 0) return false;
    if (bars.some(t => t.includes('Open plan'))) return false;
    return bars.some(t => t.includes('E2E Demo') && t.includes('Completed'));
  }, { timeout: 30000 });
  await sleep(600);
  await shot(page, '07-chained-restart.png');
  console.log('PASS: after chained refresh, resuming the root restores the latest work copy (fork2) and rebinds');

  console.log('\nALL PASS ✅');
  console.log('screenshots:');
  for (const s of shots) console.log('  ' + s);
} finally {
  if (browser) await browser.close().catch(() => {});
  killServer();
  removeTmp();
  console.log('artifacts: ' + (KEEP_ARTIFACTS ? tmp : '<removed on exit — set ALAYAFACE_KEEP_ARTIFACTS=1 to keep screenshots>'));
}

function findPlanDirs() {
  const sessionsRoot = path.join(home, '.alayaface', 'sessions');
  const out = [];
  if (!existsSync(sessionsRoot)) return out;
  for (const sess of readdirSync(sessionsRoot)) {
    const plans = path.join(sessionsRoot, sess, 'plans');
    if (!existsSync(plans)) continue;
    for (const pd of readdirSync(plans)) out.push(path.join(plans, pd));
  }
  return out;
}

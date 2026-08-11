#!/usr/bin/env node
// Cascade-fork E2E — the FULL re-run cascade with a truncating fork.
//
//   session S (plan mode) → "give me a plan" → plan P1 auto-creates
//   → Run → completed → [Plan Result] inserted into S
//   → RE-RUN with the version marker (fakecore replies differ, so the
//     cascade gate passes) → S is FORKED to S' (session.alaya truncated
//     up to the old [Plan Result], then replayed by the forked process)
//     → S' registers its lineage + replays the truncated history + gets
//       the new [Plan Result]; the original S window closes.
//
// Assertions (regression for the user-reported bug + P39-B3 lineage):
//   * the replayed plan message in S' binds the status bar to
//     "[Plan: e2e-demo-…] E2E Demo · Completed" — NOT the generic
//     "Open plan" fallback (the original bug: fork sessions lost the
//     plan binding because it matched origin only);
//   * the [Plan Result] message carries the [Plan: …] link with the
//     (v2) summary;
//   * no duplicate plan window / plan file (replay suppression);
//   * S' wrote sessions/<S'>/session.meta.json with conversation_id =
//     the ORIGINAL session's id (fork lineage, survives restart);
//   * the original S window is gone (adoption closed it).

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
  const clickByText = async (sel, text) => {
    const handles = await page.$$(sel);
    for (const h of handles) {
      const t = await h.evaluate(el => el.textContent || '');
      if (t.includes(text)) { await h.click(); return true; }
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
  await waitFor('.global-menu-btn');
  await page.click('.global-menu-btn');
  await waitFor('.global-menu-panel');
  assert(await clickByText('.global-menu-item', 'New Session'), 'New Session menu item');
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

  // The cascade completes → fork → S' registers lineage + replays the
  // truncated history + receives the v2 [Plan Result]; the ORIGINAL S
  // window closes. Wait for the v2 feedback message AND a status bar
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

  // d) Lineage: the fork registered session.meta.json whose
  //    conversation_id is the ORIGINAL session's id; the original
  //    session carries its own root meta (conversation = itself).
  const sessionsRoot = path.join(home, '.alayaface', 'sessions');
  const sessionDirs = readdirSync(sessionsRoot).filter(d => !d.endsWith('.tmp'));
  const lineageFiles = [];
  for (const sid of sessionDirs) {
    const f = path.join(sessionsRoot, sid, 'session.meta.json');
    if (existsSync(f)) lineageFiles.push({ sid, meta: JSON.parse(readFileSync(f, 'utf8')) });
  }
  assert(lineageFiles.length === 2, 'root meta + fork lineage meta, got: ' + JSON.stringify(lineageFiles));
  const forkEntry = lineageFiles.find(e => e.meta.parent_instance_id);
  const rootEntry = lineageFiles.find(e => !e.meta.parent_instance_id);
  assert(forkEntry && rootEntry, 'one root + one fork entry, got: ' + JSON.stringify(lineageFiles));
  assert(forkEntry.meta.conversation_id === rootEntry.sid,
    'fork lineage conversation_id = original session, got: ' + JSON.stringify(lineageFiles));
  assert(forkEntry.meta.parent_instance_id === rootEntry.sid, 'fork parent = original session');
  const rootSid = rootEntry.sid;
  const forkSid = forkEntry.sid;
  console.log('PASS: fork lineage: ' + rootSid + ' (root) → ' + forkSid + ' (fork) in session.meta.json');

  // e) The original S window is gone (adoption closed it); the fork
  //    session (with the plan status bar) is the active one — and it
  //    opened at the SAME spot as the window it replaced.
  const panelCount = await page.$$eval('.session-panel', els => els.length);
  assert(panelCount >= 1, 'fork session window present, got: ' + panelCount);
  const sPosAfter = await page.evaluate(() => {
    const p = document.querySelector('.session-panel:not(.plan-panel)');
    const cs = getComputedStyle(p);
    return { left: cs.left, top: cs.top, width: cs.width, height: cs.height };
  });
  assert(JSON.stringify(sPosAfter) === JSON.stringify(sPosBefore),
    'fork session window opened at the replaced window\'s position, got before=' +
      JSON.stringify(sPosBefore) + ' after=' + JSON.stringify(sPosAfter));
  console.log('PASS: fork session window inherits the replaced window\'s position');
  await shot(page, '04-final.png');
  console.log('PASS: original session closed, fork session takes over');

  // ── 8. RESTART consistency (P39-B5) ───────────────────────────────
  // Page refresh: close_all_sessions gracefully saves every session
  // (fakecore's save KEEPS the fork's truncated history), then the
  // plan-meta scan rebuilds planMetas AND the lineage registry from the
  // session.meta.json files. Resume the FORK (the conversation HEAD) →
  // it replays its truncated history → the replayed plan message binds
  // the status bar through the REBUILT registry (no "Open plan").
  await page.reload({ waitUntil: 'networkidle0', timeout: 30000 });
  await waitFor('.global-menu-btn');
  await sleep(2000); // close_all_sessions + planMetas/lineage scan settle
  await page.click('.global-menu-btn');
  await waitFor('.global-menu-panel');
  assert(await clickByText('.global-menu-item', 'Session Manager'), 'Session Manager menu item (refresh)');
  // The overlay list may be considered non-visible by Puppeteer (scroll
  // container); wait for presence, not visibility.
  await page.waitForSelector('.sel-page-item', { timeout: 10000 });
  const resumedFork = await page.evaluate((fid) => {
    const items = [...document.querySelectorAll('.sel-page-item')];
    for (const it of items) {
      const name = it.querySelector('.sel-page-item-name')?.textContent || '';
      const btn = [...it.querySelectorAll('button')].find(b => b.textContent.trim() === 'Resume');
      if (name === fid.slice(0, 8) && btn && !btn.disabled) { btn.click(); return true; }
    }
    return false;
  }, forkSid);
  assert(resumedFork, 'fork (head) session Resume clickable after refresh');
  // The resumed fork replays its truncated history; the replayed plan
  // message must bind via the REBUILT lineage registry.
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
  console.log('PASS: after refresh, resuming the fork (head) rebinds the status bar via the rebuilt lineage (no duplicate plan)');

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

  // Multi-level lineage on disk: root → fork1 (parent root) → fork2
  // (parent fork1), all sharing the root's conversation id.
  const sessionsRoot2 = path.join(home, '.alayaface', 'sessions');
  const lineage2 = [];
  for (const sid of readdirSync(sessionsRoot2).filter(d => !d.endsWith('.tmp'))) {
    const f = path.join(sessionsRoot2, sid, 'session.meta.json');
    if (existsSync(f)) lineage2.push({ sid, meta: JSON.parse(readFileSync(f, 'utf8')) });
  }
  assert(lineage2.length === 3, 'three lineage metas (root + 2 forks), got: ' + JSON.stringify(lineage2));
  const root2 = lineage2.find(e => !e.meta.parent_instance_id);
  const fork1 = lineage2.find(e => e.meta.parent_instance_id === root2.sid);
  const fork2 = lineage2.find(e => e.meta.parent_instance_id === fork1.sid);
  assert(root2 && fork1 && fork2, 'lineage chain root→fork1→fork2, got: ' + JSON.stringify(lineage2));
  assert(fork2.meta.conversation_id === root2.sid, 'fork2 conversation = root, got: ' + JSON.stringify(lineage2));
  const fork1Sid = fork1.sid;
  const fork2Sid = fork2.sid;
  console.log('PASS: chained fork lineage on disk: ' + root2.sid + ' → ' + fork1Sid + ' → ' + fork2Sid);

  // ── 10. RESTART with a 3-deep chain ────────────────────────────────
  // headInstanceFor must resolve the HEAD to fork2 (the only instance
  // that is nobody's parent) — resuming it replays the truncated history
  // and binds the status bar via the REBUILT lineage.
  await page.reload({ waitUntil: 'networkidle0', timeout: 30000 });
  await waitFor('.global-menu-btn');
  await sleep(2000); // close_all_sessions + planMetas/lineage scan settle
  await page.click('.global-menu-btn');
  await waitFor('.global-menu-panel');
  assert(await clickByText('.global-menu-item', 'Session Manager'), 'Session Manager menu item (chained refresh)');
  await page.waitForSelector('.sel-page-item', { timeout: 10000 });
  const resumedHead = await page.evaluate((fid) => {
    const items = [...document.querySelectorAll('.sel-page-item')];
    for (const it of items) {
      const name = it.querySelector('.sel-page-item-name')?.textContent || '';
      const btn = [...it.querySelectorAll('button')].find(b => b.textContent.trim() === 'Resume');
      if (name === fid.slice(0, 8) && btn && !btn.disabled) { btn.click(); return true; }
    }
    return false;
  }, fork2Sid);
  assert(resumedHead, 'head (fork2) Resume clickable after chained refresh');
  await page.waitForFunction(() => {
    const bars = [...document.querySelectorAll('.plan-offer-btn')].map(e => e.textContent || '');
    if (bars.length === 0) return false;
    if (bars.some(t => t.includes('Open plan'))) return false;
    return bars.some(t => t.includes('E2E Demo') && t.includes('Completed'));
  }, { timeout: 30000 });
  await sleep(600);
  await shot(page, '07-chained-restart.png');
  console.log('PASS: after chained refresh, head resolution found fork2 (3-deep) and it rebinds via the rebuilt lineage');

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

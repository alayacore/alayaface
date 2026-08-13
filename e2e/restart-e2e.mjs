#!/usr/bin/env node
// Restart-persistence E2E: create a plan, run it to completion, RESTART
// the backend (same HOME), reload the UI, reopen the plan via the
// session's [Plan: …] status-bar link and assert the run state (dot +
// node statuses) came back from run.json / meta.json.
//
// Screenshots land in the artifact dir; ALL PASS printed on success.
// The tmp dir is removed on exit — set ALAYAFACE_KEEP_ARTIFACTS=1 to keep
// the screenshots for debugging. Signal handlers (Ctrl-C / SIGTERM) kill
// the backend child too, so no orphan server is left behind.

import puppeteer from 'puppeteer-core';
import { execSync, spawn } from 'node:child_process';
import { mkdtempSync, existsSync, readdirSync, readFileSync, rmSync } from 'node:fs';
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
        if (Date.now() > deadline) reject(new Error('server port timeout'));
        else setTimeout(tick, 250);
      });
    };
    tick();
  });
}

const tmp = mkdtempSync(path.join(tmpdir(), 'alayaface-restart-'));
const home = path.join(tmp, 'home');
const artifacts = path.join(tmp, 'shots');
const SRCGO = path.join(ROOT, 'src-go');
execSync(`mkdir -p "${artifacts}" "${home}"`);

const fakecore = path.join(tmp, 'fakecore');
const serverBin = path.join(tmp, 'alayaface-server');
execSync('go build -o "' + fakecore + '" ./internal/fakecore', { cwd: SRCGO, stdio: 'inherit' });
execSync('go build -o "' + serverBin + '" ./cmd/alayaface-server', { cwd: SRCGO, stdio: 'inherit' });

const port = await freePort();
const base = `http://127.0.0.1:${port}`;

async function startServer() {
  const s = spawn(serverBin, ['--addr', `127.0.0.1:${port}`, '--static', '../src-elm', '--alayacore-bin', fakecore], {
    cwd: SRCGO,
    env: { ...process.env, HOME: home },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  s.stdout.on('data', d => process.stdout.write('[srv] ' + d));
  s.stderr.on('data', d => process.stdout.write('[srv!] ' + d));
  await waitPort(port, 30000);
  return s;
}

// Resolve once the child has fully exited (or after ms — the graceful
// shutdown may close sessions for a while before the port is released).
function waitExit(proc, ms) {
  return new Promise((resolve) => {
    if (proc.exitCode !== null || proc.signalCode !== null) return resolve();
    const t = setTimeout(() => resolve(), ms);
    proc.once('exit', () => { clearTimeout(t); resolve(); });
  });
}

let server;
let browser;

async function launchChrome() {
  const b = await puppeteer.launch({
    executablePath: CHROME,
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu', '--window-size=1440,920'],
  });
  const page = await b.newPage();
  await page.setViewport({ width: 1440, height: 920 });
  page.on('pageerror', e => console.log('[pageerror]', e.message));
  return { b, page };
}

const sleep = ms => new Promise(r => setTimeout(r, ms));

// The global menu is opened by RIGHT-CLICKING the canvas (the fixed
// ⚙ button was removed) and closed by clicking outside the menu.
// Page is passed explicitly because restart-e2e relaunches Chrome.
const openGlobalMenu = async (pg) => {
  await pg.waitForSelector('.main-content', { timeout: 30000 });
  await pg.$eval('.main-content', el => el.dispatchEvent(
    new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 30, clientY: 30 })));
  await pg.waitForSelector('.global-menu-panel', { timeout: 10000, visible: true });
};

// ── cleanup ─────────────────────────────────────────────────────────
// Remove the tmp dir on exit (unless ALAYAFACE_KEEP_ARTIFACTS=1 — useful
// to inspect screenshots after a failed run). Signal handlers also kill
// the backend child, so Ctrl-C / SIGTERM cannot orphan a server process.
const KEEP_ARTIFACTS = process.env.ALAYAFACE_KEEP_ARTIFACTS === '1';
function removeTmp() {
  if (KEEP_ARTIFACTS) return;
  try { rmSync(tmp, { recursive: true, force: true }); } catch {}
}
function killServer() {
  try { if (server) server.kill('SIGTERM'); } catch {}
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
  // ── Phase 1: create + run a plan ──────────────────────────────────
  server = await startServer();
  let chrome = await launchChrome();
  browser = chrome.b;
  let page = chrome.page;
  await page.goto(base + '/', { waitUntil: 'networkidle0', timeout: 30000 });
  await openGlobalMenu(page);
  await page.waitForSelector('.global-menu-panel');
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
  assert(await newSession('Simple'), 'New Session → preset submenu');
  await page.waitForSelector('.session-panel');
  await sleep(600);
  // Type into the newest session.
  await page.evaluate(() => {
    const panels = [...document.querySelectorAll('.session-panel')];
    let bestN = -1;
    for (const p of panels) {
      const m = (p.querySelector('.session-bar-title')?.textContent || '').match(/Session (\d+)/);
      if (m) bestN = Math.max(bestN, parseInt(m[1], 10));
    }
    for (const p of panels) {
      const m = (p.querySelector('.session-bar-title')?.textContent || '').match(/Session (\d+)/);
      if (!m || parseInt(m[1], 10) !== bestN) continue;
      const ta = p.querySelector('textarea.input-text');
      if (ta) {
        ta.value = 'Create a demo plan for restart test';
        ta.dispatchEvent(new Event('input', { bubbles: true }));
      }
      const btn = p.querySelector('.send-btn');
      if (btn) btn.click();
    }
  });
  await page.waitForSelector('.plan-page', { timeout: 30000 });
  await sleep(800);
  assert(await clickByText('button.plan-strip-btn', 'Run'), 'Run button');
  await page.waitForFunction(() => {
    return [...document.querySelectorAll('.plan-offer-btn')].some(e => e.textContent.includes('Completed'));
  }, { timeout: 120000 });
  await sleep(600);
  console.log('PASS: phase 1 — plan ran to completion');

  // Capture the planId + origin session + run state files on disk.
  const sessionsRoot = path.join(home, '.alayaface', 'sessions');
  const planDirs = [];
  for (const sess of readdirSync(sessionsRoot)) {
    const plans = path.join(sessionsRoot, sess, 'plans');
    if (!existsSync(plans)) continue;
    for (const pd of readdirSync(plans)) planDirs.push(path.join(plans, pd));
  }
  assert(planDirs.length === 1, 'one plan dir, got: ' + JSON.stringify(planDirs));
  const planDir = planDirs[0];
  const planId = path.basename(planDir);
  assert(existsSync(path.join(planDir, planId + '.run.json')), 'run.json written before restart');
  const runBefore = JSON.parse(readFileSync(path.join(planDir, planId + '.run.json'), 'utf8'));
  assert(runBefore.status === 'completed', 'run.json status before restart: ' + runBefore.status);
  console.log('PASS: run.json on disk before restart: status=' + runBefore.status + ', nodes=' + Object.keys(runBefore.nodes).join(','));

  // ── Phase 1.5: PAGE REFRESH (same backend) ────────────────────────
  // A page refresh orphans the open session handles — the backend still
  // holds them, so resume_session would keep failing with "Session is
  // already active" until the backend process is restarted. The new
  // page must reclaim them via close_all_sessions on init.
  const originDir = readdirSync(sessionsRoot).find(sess =>
    existsSync(path.join(sessionsRoot, sess, 'plans', planId, planId + '.meta.json')));
  assert(originDir, 'origin session dir found on disk');
  await page.reload({ waitUntil: 'networkidle0', timeout: 30000 });
  // Let close_all_sessions (orphan reclaim) + the planMetas scan settle.
  await sleep(1500);
  await page.screenshot({ path: path.join(artifacts, 'r0-after-refresh.png') });
  await openGlobalMenu(page);
  assert(await clickByText('.global-menu-item', 'Session Manager'), 'Session Manager menu item (refresh)');
  await page.waitForSelector('.sel-page-item', { timeout: 10000 });
  const refreshed = await page.evaluate((prefix) => {
    const items = [...document.querySelectorAll('.sel-page-item')];
    for (const it of items) {
      const name = it.querySelector('.sel-page-item-name')?.textContent || '';
      const btn = [...it.querySelectorAll('button')].find(b => b.textContent.trim() === 'Resume');
      if (name === prefix.slice(0, 8) && btn && !btn.disabled) { btn.click(); return true; }
    }
    return false;
  }, originDir);
  assert(refreshed, 'origin session Resume clickable after page refresh (no "Session is already active")');
  // The resumed session replays its history → the [Plan: …] status bar
  // appears (planMetas origin binding works after refresh too).
  await page.waitForFunction(() => {
    return [...document.querySelectorAll('button')].some(e => /^\[Plan: /.test((e.textContent || '').trim()));
  }, { timeout: 30000 });
  await sleep(600);
  console.log('PASS: page refresh — resume works, no "Session is already active"');

  // ── Phase 2: restart the backend + reload the UI ──────────────────
  await page.close();
  await browser.close();
  server.kill('SIGTERM');
  // Wait for the OLD server to release the port before starting the new
  // one (graceful shutdown closes its sessions first; starting early made
  // the new process fail to bind and the page talk to the dying server).
  await waitExit(server, 15000);
  server = await startServer();
  console.log('PASS: backend restarted (same HOME)');

  chrome = await launchChrome();
  browser = chrome.b;
  page = chrome.page;
  await page.goto(base + '/', { waitUntil: 'networkidle0', timeout: 30000 });
  // Let the planMetas index rebuild finish (sessions/ → plans/ → reads).
  await sleep(2500);
  await page.screenshot({ path: path.join(artifacts, 'r1-after-restart.png') });

  // The [Plan: …] status bar lives in the ORIGIN session's message view —
  // after restart the user resumes that session (Session Manager), the
  // replayed plan message re-binds via planMetas, and the status-bar
  // button reopens the plan. Do exactly that (originDir from phase 1.5):
  await openGlobalMenu(page);
  assert(await clickByText('.global-menu-item', 'Session Manager'), 'Session Manager menu item');
  await page.waitForSelector('.sel-page-item', { timeout: 10000 });
  // Resume the origin session (identified by its id prefix).
  const resumed = await page.evaluate((prefix) => {
    const items = [...document.querySelectorAll('.sel-page-item')];
    for (const it of items) {
      const name = it.querySelector('.sel-page-item-name')?.textContent || '';
      const btn = [...it.querySelectorAll('button')].find(b => b.textContent.trim() === 'Resume');
      if (name === prefix.slice(0, 8) && btn) { btn.click(); return true; }
    }
    return false;
  }, originDir);
  assert(resumed, 'origin session Resume clicked in the Session Manager');
  // The resumed session replays its history → the [Plan: …] status bar
  // appears under the plan message (planMetas origin binding).
  await page.waitForFunction(() => {
    return [...document.querySelectorAll('button')].some(e => /^\[Plan: /.test((e.textContent || '').trim()));
  }, { timeout: 30000 });
  await sleep(600);
  const planButtons = await page.$$eval('button', els => els.filter(e => /^\[Plan: /.test((e.textContent || '').trim())).map(e => e.textContent.trim()));
  assert(planButtons.length >= 1, 'status-bar [Plan: …] button after restart+resume, got: ' + JSON.stringify(planButtons));
  console.log('PASS: [Plan: …] status bar present after restart:', planButtons[0]);

  // Click it → the plan reopens from disk with its run state restored.
  await page.evaluate(() => {
    const b = [...document.querySelectorAll('button')].find(e => /^\[Plan: /.test((e.textContent || '').trim()));
    if (b) b.click();
  });
  await page.waitForSelector('.plan-page', { timeout: 30000 });
  await sleep(1000);
  await page.screenshot({ path: path.join(artifacts, 'r2-reopened.png') });

  const restored = await page.evaluate(() => {
    const dot = document.querySelector('.plan-run-dot');
    const nodeCounts = {};
    for (const el of document.querySelectorAll('.plan-node')) {
      const cls = el.className || '';
      const m = cls.match(/plan-node-([a-z-]+)/);
      if (m) nodeCounts[m[1]] = (nodeCounts[m[1]] || 0) + 1;
    }
    return {
      dot: dot ? dot.className : null,
      nodeCounts,
      nodes: document.querySelectorAll('.plan-node').length,
    };
  });
  assert(restored.dot && restored.dot.includes('plan-run-dot-completed'),
    'run state restored after restart, got: ' + JSON.stringify(restored));
  assert(restored.nodes === 3, 'DAG has 3 nodes after restart, got: ' + JSON.stringify(restored));
  assert(restored.nodeCounts.succeeded === 3,
    'all 3 nodes restored as succeeded, got: ' + JSON.stringify(restored));
  console.log('PASS: run state restored after restart — dot ' + restored.dot + ', nodes ' + JSON.stringify(restored.nodeCounts));

  console.log('\nALL PASS ✅');
  console.log(KEEP_ARTIFACTS ? `artifacts: ${tmp}` : 'artifacts: <removed on exit — set ALAYAFACE_KEEP_ARTIFACTS=1 to keep screenshots>');
} finally {
  if (browser) await browser.close().catch(() => {});
  killServer();
  removeTmp();
}

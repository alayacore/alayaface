#!/usr/bin/env node
// Plan Mode E2E — headless Chrome + Go backend + fakecore (no real model).
//
// Flow:
//   1. build fakecore + Go server (fresh HOME), start both
//   2. Chrome headless → ⚙ → New Session → send a prompt
//   3. fakecore answers with a fenced plan JSON → plan auto-creates
//   4. Plan window DAG → Run (concurrency fixed at 8, P37 — no header input)
//   5. t1 ok → t2 fails once (marker) → auto-retry → ok → t3 ok → Completed
//   6. Node detail: t2 shows failure history + ≥2 attempt sessions
//   7. Click t1 node → its session window activates and shows the reply
//
// P28/P30: plans live INSIDE the session that created them
// (sessions/<origin>/plans/<planId>/ — document/meta/run/work + node
// sessions); no plan import; no Plans manager — plans are reopened via
// the session's [Plan: …] status-bar link.
//
// Screenshots land in the artifact dir; ALL PASS printed on success.
// The tmp dir is removed on exit — set ALAYAFACE_KEEP_ARTIFACTS=1 to keep
// the screenshots for debugging. Signal handlers (Ctrl-C / SIGTERM) kill
// the backend child too, so no orphan server is left behind.

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

const tmp = mkdtempSync(path.join(tmpdir(), 'alayaface-e2e-'));
const home = path.join(tmp, 'home');
const artifacts = path.join(tmp, 'shots');
const serverLog = path.join(tmp, 'server.log');
const SRCGO = path.join(ROOT, 'src-go');
execSync(`mkdir -p "${artifacts}" "${home}"`);
// fail-once markers are shared under os.TempDir (keyed by prompt hash);
// clean them so a fresh run exercises the failure path again.
execSync('rm -f /tmp/alayaface-fakecore-fail-once-*.marker /tmp/alayaface-fakecore-hang-once-*.marker');
// R1 removed task timeouts, so t3's hang-once can no longer be recovered
// by a timeout on the FIRST run. Pre-seed t3's hang marker (keyed by its
// prompt hash, same scheme as fakecore) → the first run succeeds
// instantly; step 8b rm's the markers so the re-run hangs again.
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

// ── 2. start Go backend (fresh HOME → presets seed; ALAYACORE_BIN=fakecore)
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

  // ── 4. Plan Session → offer ───────────────────────────────────────
  await page.goto(base + '/', { waitUntil: 'networkidle0', timeout: 30000 });
  await waitFor('.global-menu-btn');
  await page.click('.global-menu-btn');
  await waitFor('.global-menu-panel');
  // R2: no "New Plan Session" — every session is plan-capable.
  assert(await clickByText('.global-menu-item', 'New Session'), 'New Session menu item');

  // A plain session window appears (no [Plan] prefix anymore).
  await waitFor('.session-panel');
  await sleep(600);

  // Send the user prompt into the NEWEST session (the one we just
  // created — no session is auto-created at startup anymore).
  const planPanel = await page.$$eval('.session-panel', panels => {
    let best = null;
    let bestN = -1;
    for (const p of panels) {
      const t = p.querySelector('.session-bar-title')?.textContent || '';
      const m = t.match(/Session (\d+)/);
      const n = m ? parseInt(m[1], 10) : -1;
      if (n > bestN) {
        bestN = n;
        best = { has: true, title: t, ta: !!p.querySelector('textarea.input-text'), btn: !!p.querySelector('.send-btn') };
      }
    }
    return best || { has: false };
  });
  console.log('plan panel:', JSON.stringify(planPanel));
  assert(planPanel.has, 'new session window not found');

  await page.evaluate(() => {
    const panels = [...document.querySelectorAll('.session-panel')];
    let bestN = -1;
    for (const p of panels) {
      const t = p.querySelector('.session-bar-title')?.textContent || '';
      const m = t.match(/Session (\d+)/);
      const n = m ? parseInt(m[1], 10) : -1;
      if (n > bestN) bestN = n;
    }
    for (const p of panels) {
      const t = p.querySelector('.session-bar-title')?.textContent || '';
      const m = t.match(/Session (\d+)/);
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
  await sleep(800);
  await shot(page, '00-after-send.png');

  // fakecore answers with the fenced plan JSON → R2 AUTO-CREATES the
  // plan window (no button).
  await waitFor('.plan-page', 30000);
  await sleep(800);
  await shot(page, '01-auto-created-plan.png');
  console.log('PASS: plan auto-created (no button)');

  // ── 4b. Plan window ↔ owning session curve ────────────────────────
  // The active plan window is connected to the session that auto-created
  // it: bridge.js draws the plan-connection overlay, anchored on the
  // session's [Plan: <planId>] button when visible. The curve must be a
  // SOLID, thicker line (both connection curves share that style).
  const planConnState = async () => {
    return page.evaluate(() => {
      const svg = [...document.querySelectorAll('.connection-seg')]
        .find(s => s.querySelector('.plan-connection-curve')) || null;
      const path = svg ? svg.querySelector('path') : null;
      const d = path ? (path.getAttribute('d') || '') : '';
      const nums = d.split(/[ MC,]/).filter(Boolean).map(Number);
      const visible = svg ? getComputedStyle(svg).display !== 'none' : false;
      const style = path ? getComputedStyle(path) : null;
      // The [Plan: …] button inside the origin session (status bar).
      const btn = [...document.querySelectorAll('button')]
        .find(b => /^\[Plan: /.test((b.textContent || '').trim()));
      const br = btn ? btn.getBoundingClientRect() : null;
      const nodeSvg = [...document.querySelectorAll('.connection-seg')]
        .find(s => s.querySelector('.node-connection-curve')) || null;
      return {
        visible,
        hasPath: d.length > 10,
        endX: nums.length >= 2 ? nums[nums.length - 2] : null,
        endY: nums.length >= 2 ? nums[nums.length - 1] : null,
        btn: br ? { x: br.left + br.width / 2, y: br.top + br.height / 2, text: (btn.textContent || '').slice(0, 40) } : null,
        dash: style ? getComputedStyle(path).strokeDasharray : null,
        width: style ? parseFloat(getComputedStyle(path).strokeWidth) : null,
        nodeVisible: nodeSvg ? getComputedStyle(nodeSvg).display !== 'none' : false,
      };
    });
  };
  // Scroll the [Plan: …] status-bar button into view so the curve
  // anchors to it (bridge.js falls back to the window edge otherwise).
  await page.evaluate(() => {
    const btn = [...document.querySelectorAll('button')]
      .find(b => /^\[Plan: /.test((b.textContent || '').trim()));
    if (btn) btn.scrollIntoView({ block: 'center' });
  });
  await sleep(400);
  let pcs = await planConnState();
  assert(pcs.visible, 'plan↔session overlay visible, got: ' + JSON.stringify(pcs));
  assert(pcs.hasPath, 'plan↔session curve has a path, got: ' + JSON.stringify(pcs));
  assert(pcs.btn, 'origin session has a [Plan: …] button, got: ' + JSON.stringify(pcs));
  assert(pcs.endX !== null && Math.abs(pcs.endX - pcs.btn.x) < 8 && Math.abs(pcs.endY - pcs.btn.y) < 8,
    'plan↔session curve anchored to the [Plan: …] button, got: ' + JSON.stringify(pcs));
  assert(pcs.dash === 'none' || pcs.dash === '', 'connection curve is SOLID (no dash), got: ' + JSON.stringify(pcs));
  assert(pcs.width >= 3, 'connection curve is thicker (stroke-width ≥ 3), got: ' + JSON.stringify(pcs));
  assert(!pcs.nodeVisible, 'node↔session overlay hidden while the plan is active, got: ' + JSON.stringify(pcs));
  console.log('PASS: plan↔session curve visible + solid/thick + anchored to the [Plan: …] button');
  await shot(page, '01b-plan-session-connection.png');

  // ── 5. Plan window → Run ──────────────────────────────────────────
  const nodeIds = await page.$$eval('.plan-node-id', els => els.map(e => e.textContent));
  assert(nodeIds.includes('t1') && nodeIds.includes('t2') && nodeIds.includes('t3'),
    'DAG nodes t1/t2/t3, got: ' + JSON.stringify(nodeIds));
  console.log('PASS: Plan window with DAG nodes', JSON.stringify(nodeIds));

  // P37: concurrency is fixed at 8 (no header input); Run lives in the
  // overlay strip on the canvas.
  assert(await clickByText('button.plan-strip-btn', 'Run'), 'Run button');

  // R4: the run completes → succeeded node windows close AND the plan
  // window auto-closes (D10/D11, feedback queued first). So wait for the
  // STATUS BAR to flip to Completed instead of the plan window badge.
  await page.waitForFunction(() => {
    return [...document.querySelectorAll('.plan-offer-btn')].some(e => e.textContent.includes('Completed'));
  }, { timeout: E2E_TIMEOUT });
  await sleep(500);
  await shot(page, '03-completed.png');
  // Plan window is gone after auto-close.
  const planGone = await page.$$eval('.plan-page', els => els.length);
  assert(planGone === 0, 'Completed plan window auto-closed, got: ' + planGone);
  console.log('PASS: run completed, nodes succeeded, plan window auto-closed');

  // ── 5b. R3: feedback + status bar ────────────────────────────────
  // The completed plan feeds its results back to the origin (plain)
  // session as a "[Plan Result]" prompt carrying a [Plan: <planId>] link,
  // and the plan JSON message gets a status bar (bound via meta.json).
  await sleep(600);
  const fbTexts = await page.$$eval('.message-content', els => els.map(e => e.textContent));
  assert(fbTexts.some(t => t.includes('[Plan Result]')), 'feedback sent to the origin session, got: ' + JSON.stringify(fbTexts.slice(-3)));
  assert(fbTexts.some(t => t.includes('[Plan: e2e-demo-')), 'feedback carries the plan link, got: ' + JSON.stringify(fbTexts.slice(-3)));
  const statusBars = await page.$$eval('.plan-offer-btn', els => els.map(e => e.textContent));
  assert(statusBars.some(t => t.includes('Completed')), 'status bar shows Completed, got: ' + JSON.stringify(statusBars));
  console.log('PASS: R3 feedback sent to origin session + plan status bar shows Completed');

  // ── 5c. Text selection survives mouseup (no focus steal) ──────────
  // Regression: clicking inside the active session window used to fire
  // Ev.onClick SwitchSession, whose "already active" branch re-focused
  // the input (Dom.focus) — clearing the user's text selection on
  // mouseup. Select a message and assert the selection is kept.
  // The origin session is identified by its plan status bar; it is
  // activated first so its window sits on top (other windows would
  // intercept the synthetic mouse events otherwise).
  const originIdx = await page.evaluate(() => {
    const panels = [...document.querySelectorAll('.session-panel')];
    return panels.findIndex(p => p.querySelector('.plan-offer'));
  });
  assert(originIdx >= 0, 'origin session (with plan status bar) not found');
  await page.evaluate(idx => {
    document.querySelectorAll('.session-panel')[idx].querySelector('.session-bar').dispatchEvent(new MouseEvent('mousedown', { bubbles: true }));
    document.querySelectorAll('.session-panel')[idx].querySelector('.session-bar').dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
  }, originIdx);
  await sleep(200);
  const selBox = await page.$$eval('.session-panel .message-assistant .msg-body .message-content', els => {
    const el = els.find(e => (e.textContent || '').length > 20);
    if (!el) return null;
    // The message may be scrolled out of view (e.g. below the plan
    // feedback); bring it into view first so the synthetic mouse events
    // land on it.
    el.scrollIntoView({ block: 'center' });
    return { found: true };
  });
  assert(selBox, 'no selectable assistant message found');
  await sleep(200);
  const selBox2 = await page.$$eval('.session-panel .message-assistant .msg-body .message-content', els => {
    const el = els.find(e => {
      const r = e.getBoundingClientRect();
      return (e.textContent || '').length > 20 && r.top >= 0 && r.bottom <= window.innerHeight;
    });
    if (!el) return null;
    const r = el.getBoundingClientRect();
    // Click inside the BODY (below the collapsible msg-header) so the
    // mouseup click does not hit ToggleMsgCollapse.
    return { x: r.left + 20, y: r.top + Math.min(r.height / 2, 20), w: Math.min(r.width - 40, 120) };
  });
  assert(selBox2, 'no selectable assistant message in viewport');
  console.log('5c selBox:', JSON.stringify(selBox2));
  await page.mouse.move(selBox2.x, selBox2.y);
  await page.mouse.down();
  await page.mouse.move(selBox2.x + selBox2.w, selBox2.y + 8, { steps: 5 });
  await page.mouse.up();
  await sleep(200);
  const selKept = await page.evaluate(() => {
    const s = window.getSelection();
    return !!(s && !s.isCollapsed && s.toString().length > 0);
  });
  assert(selKept, 'text selection cleared after mouseup (focus steal bug)');
  console.log('PASS: message text selection survives mouseup (no focus steal)');

  // Per-plan working directory: node sessions were spawned with
  // sessions/<origin>/plans/<planId>/work as their cwd (created by the
  // backend). Plans live INSIDE the session that created them.
  const sessionsRoot = path.join(home, '.alayaface', 'sessions');
  const findPlanDirs = () => {
    const out = [];
    for (const sess of readdirSync(sessionsRoot)) {
      const plans = path.join(sessionsRoot, sess, 'plans');
      if (!existsSync(plans)) continue;
      for (const pd of readdirSync(plans)) out.push(path.join(plans, pd));
    }
    return out;
  };
  const planDirs = findPlanDirs();
  const workDirs = planDirs.map(d => path.join(d, 'work')).filter(existsSync);
  assert(workDirs.length >= 1, 'plan work dir exists, found: ' + JSON.stringify(workDirs));
  assert(planDirs.length === 1, 'exactly one plan dir under sessions/, got: ' + JSON.stringify(planDirs));
  console.log('PASS: plan work dir isolated:', workDirs[0]);

  // ── 5d. Session directory hierarchy ───────────────────────────────
  // Plan node sessions are nested under
  // sessions/<originSessionId>/plans/<planId>/<nodeId>/ so the sessions/
  // top level only ever contains plain (non-plan) sessions. The origin
  // (plain) session stays at the top level; its plans/ subtree holds the
  // plan document + work + one dir per node, each containing session
  // dirs.
  const sessTop = readdirSync(sessionsRoot).filter(n => !n.startsWith('.'));
  const planDir = planDirs[0];
  const planId = path.basename(planDir);
  assert(planId.startsWith('e2e-demo-'), 'plan dir named by planId, got: ' + planId);
  assert(existsSync(path.join(planDir, planId + '.json')), 'plan document inside its session dir');
  assert(existsSync(path.join(planDir, planId + '.meta.json')), 'plan meta inside its session dir');
  const nodeDirs = readdirSync(planDir).filter(n => !n.startsWith('.') && !n.endsWith('.json') && n !== 'work');
  for (const nd of nodeDirs) {
    const uuids = readdirSync(path.join(planDir, nd)).filter(n => !n.startsWith('.'));
    assert(uuids.length >= 1, planId + '/' + nd + ': contains session dir(s), got: ' + JSON.stringify(uuids));
  }
  assert(['t1', 't2', 't3'].every(n => nodeDirs.includes(n)),
    planId + ': node subdirs t1/t2/t3, got: ' + JSON.stringify(nodeDirs));
  // Top-level entries: plain session uuids only (the plan lives under
  // its origin session — no plan dir / plan child uuid at the top).
  assert(sessTop.every(n => !n.startsWith('e2e-demo-')), 'no plan dir at the sessions top level, got: ' + JSON.stringify(sessTop));
  assert(sessTop.length >= 1, 'plain origin session remains at top level, got: ' + JSON.stringify(sessTop));
  console.log('PASS: session dir hierarchy — plan + node sessions nested under sessions/<origin>/plans/<planId>/');

  // ── 6. Retry evidence: t2 failed once and auto-retried ─────────────
  // (The plan window auto-closed on completion — reopen it via the
  // status bar [Plan: …] button, which also exercises PlanStatusOpen.
  // The in-memory run log is not persisted, so the retry evidence is
  // asserted from run.json on disk: t2 has attempts=1.)
  await page.evaluate(() => {
    const btns = [...document.querySelectorAll('.plan-offer-btn')];
    const b = btns.find(x => x.textContent.includes('[Plan: e2e-demo-'));
    if (b) b.click();
  });
  await waitFor('.plan-page', 10000);
  await sleep(500);
  const runJsonPath = path.join(planDir, planId + '.run.json');
  assert(existsSync(runJsonPath), 'run.json exists for the e2e plan at ' + runJsonPath);
  const runJson = JSON.parse(readFileSync(runJsonPath, 'utf8'));
  console.log('run.json status:', runJson.status, 'concurrency:', runJson.concurrency);
  const t2n = runJson.nodes && runJson.nodes.t2;
  assert(t2n && t2n.attempts === 1, 'run.json: t2 attempted once (auto-retry), got: ' + JSON.stringify(t2n));
  assert(t2n.status === 'succeeded', 'run.json: t2 succeeded after retry, got: ' + t2n.status);
  assert(runJson.nodes.t1.status === 'succeeded' && runJson.nodes.t3.status === 'succeeded',
    'run.json: t1/t3 succeeded, got: ' + JSON.stringify([runJson.nodes.t1 && runJson.nodes.t1.status, runJson.nodes.t3 && runJson.nodes.t3.status]));
  console.log('PASS: t2 failed once → auto-retry (run.json attempts=1):', JSON.stringify(t2n));

  // ── 7. Click t1 node → its session window resumes ─────────────────
  // R4: succeeded node windows are closed — clicking the node RESUMES
  // its on-disk session (fakecore replays a canned plan-message history
  // on resume; the frontend must suppress plan auto-create during that
  // replay — asserted below in step 8). Here we assert the resume
  // succeeded: window with the /t1 badge and no plan error.
  await clickNode(page, 't1');
  await sleep(1000);
  const active = await page.evaluate(() => {
    const p = document.querySelector('.session-panel.session-panel-active .session-bar-title');
    return p ? p.textContent : '';
  });
  assert(active.includes('/t1'), 't1 session activated (resumed), got: ' + active);
  const planErrorCount = async () => {
    const errs = await page.$$eval('.plan-page .sel-page-status-error', els => els.map(e => e.textContent));
    return errs.filter(t => t && t.length > 0).length;
  };
  assert((await planErrorCount()) === 0, 'resume produced no plan error');
  await shot(page, '05-t1-session.png');
  console.log('PASS: t1 node opened its session (resumed, no error)');

  // ── 7b. Node ↔ session connection CHAIN ──────────────────────────
  // Focusing a plan-node session raises the plan window to the SECOND
  // layer (session z = plan z + 1) and bridge.js draws the FULL
  // connection chain: the node↔session bezier PLUS the plan↔owning
  // session bezier up to the top-level session (P36 — the whole path is
  // visible, so the lines lead all the way up to the topmost window).
  const connState = async () => {
    const st = await page.evaluate(() => {
      const svg = [...document.querySelectorAll('.connection-seg')]
        .find(s => s.querySelector('.node-connection-curve')) || null;
      const active = document.querySelector('.session-panel.session-panel-active');
      const plan = [...document.querySelectorAll('.plan-panel')]
        .find(p => [...p.querySelectorAll('.plan-node-id')].some(e => e.textContent === 't1'));
      const pathEl = svg ? svg.querySelector('path') : null;
      const planSvg = [...document.querySelectorAll('.connection-seg')]
        .find(s => s.querySelector('.plan-connection-curve')) || null;
      const planPath = planSvg ? planSvg.querySelector('path') : null;
      return {
        svgVisible: svg ? getComputedStyle(svg).display !== 'none' : false,
        pathD: svg ? (svg.querySelector('path')?.getAttribute('d') || '') : '',
        dash: pathEl ? getComputedStyle(pathEl).strokeDasharray : null,
        width: pathEl ? parseFloat(getComputedStyle(pathEl).strokeWidth) : null,
        planConnVisible: planSvg ? getComputedStyle(planSvg).display !== 'none' : false,
        planConnPathD: planSvg ? (planPath?.getAttribute('d') || '') : '',
        sessionZ: active ? parseInt(getComputedStyle(active).zIndex, 10) : -1,
        planZ: plan ? parseInt(getComputedStyle(plan).zIndex, 10) : -1,
      };
    });
    return st;
  };
  const assertConnection = async (label) => {
    const st = await connState();
    assert(st.svgVisible, label + ': connection overlay visible, got: ' + JSON.stringify(st));
    assert(st.pathD.length > 10, label + ': connection curve has a path, got: ' + JSON.stringify(st));
    assert(st.sessionZ === st.planZ + 1, label + ': plan window is one layer below the session, got: ' + JSON.stringify(st));
    assert(st.dash === 'none' || st.dash === '', label + ': connection curve is SOLID, got: ' + JSON.stringify(st));
    assert(st.width >= 3, label + ': connection curve is thicker (stroke-width ≥ 3), got: ' + JSON.stringify(st));
    // P36: the plan↔owning-session segment of the chain is drawn too —
    // the whole path up to the top-level session is visible.
    assert(st.planConnVisible, label + ': plan↔session chain segment visible (path to the top), got: ' + JSON.stringify(st));
    assert(st.planConnPathD.length > 10, label + ': plan↔session chain segment has a path, got: ' + JSON.stringify(st));
    console.log('PASS: ' + label + ' (session z=' + st.sessionZ + ', plan z=' + st.planZ + ', solid + width ' + st.width + ', chain to top visible)');
  };
  await assertConnection('node↔session connection (plan second layer + bezier)');
  await shot(page, '05a-node-connection.png');

  // ── 7c. Output injection: {{t1.output}} → t1's recorded output ────
  // t2's prompt references {{t1.output}}; the runner replaced it with
  // t1's recorded output before sending. fakecore echoes the received
  // prompt as its reply, so the injected text is IN t2's output in
  // run.json (session messages are not replayed by fakecore on resume).
  assert(t2n.output && t2n.output.includes('using upstream output:'), 't2 output carries the injection label, got: ' + JSON.stringify(t2n.output));
  assert(t2n.output.includes('research the topic and summarize findings'), 't2 output contains t1\'s recorded output');
  assert(!t2n.output.includes('{{t1.output}}'), 'raw template fully replaced');
  console.log('PASS: {{t1.output}} injected t1\'s recorded output into t2\'s prompt (no raw template)');

  // ── 8. Close/reopen node session (resume regression) ───────────────
  // The node stays bound to the ON-DISK dir id; resume_session hands out
  // a FRESH id that must NOT become the persistent binding (its dir does
  // not exist → "Session directory not found" on the next click). Close
  // the t1 session, click the node again → a NEW session window with the
  // /t1 badge appears and the plan window shows NO error. Do it twice.
  const closeT1Session = async () => {
    await page.evaluate(() => {
      const panels = [...document.querySelectorAll('.session-panel')];
      for (const p of panels) {
        const t = p.querySelector('.session-bar-title')?.textContent || '';
        if (t.includes('/t1')) {
          const btn = p.querySelector('.session-bar-close');
          if (btn) btn.click();
          break;
        }
      }
    });
  };
  const waitT1Active = async (label) => {
    await page.waitForFunction(() => {
      const t = document.querySelector('.session-panel.session-panel-active .session-bar-title')?.textContent || '';
      return t.includes('/t1');
    }, { timeout: 30000 });
    await sleep(400);
    const activeTitle = await page.$eval('.session-panel.session-panel-active .session-bar-title', e => e.textContent);
    const errCount = await planErrorCount();
    assert(errCount === 0, label + ': plan window has no resume error, got: ' + errCount);
    // Replay regression: the resumed fakecore replays a plan message
    // (mid-history); the frontend must NOT auto-create a duplicate plan
    // window or plan file from it (planReplaySessions suppression).
    const winCount = await page.$$eval('.plan-page', els => els.length);
    assert(winCount === 1, label + ': no duplicate plan window auto-created, got: ' + winCount);
    const planFiles = findPlanDirs().filter(d => {
      const n = path.basename(d);
      return n.startsWith('e2e-demo-') && existsSync(path.join(d, n + '.json'));
    });
    assert(planFiles.length === 1, label + ': no duplicate plan file, got: ' + JSON.stringify(planFiles));
    console.log('PASS: ' + label + ' — session reopened (' + activeTitle + '), no error, no duplicate plan');
    await assertConnection(label + ' — curve back after resume');
  };

  await closeT1Session();
  await sleep(500);
  const hiddenAfterClose = await page.evaluate(() => {
    const svg = [...document.querySelectorAll('.connection-seg')]
      .find(s => s.querySelector('.node-connection-curve')) || null;
    return svg ? getComputedStyle(svg).display === 'none' : true;
  });
  assert(hiddenAfterClose, 'connection curve hidden after the session window closes');
  await clickNode(page, 't1');
  await waitT1Active('close→click #1 (resume from disk)');
  await shot(page, '05b-t1-resumed-1.png');

  await closeT1Session();
  await sleep(500);
  await clickNode(page, 't1');
  await waitT1Active('close→click #2 (resume again)');
  await shot(page, '05c-t1-resumed-2.png');

  // ── 8b. Plan Stop closes the run's node session windows ───────────
  // Re-run the plan with t3 hung again (remove the hang marker; t1/t2
  // succeed instantly thanks to the persistent fail-once marker). Once
  // t3's session window is up (Running, sleeping 30s), click Stop: the
  // run badge flips to Stopped and t3's window is CLOSED (process was
  // already killed; the window must go too — no stale dead windows).
  execSync('rm -f /tmp/alayaface-fakecore-hang-once-*.marker');
  // Close the FIRST run's leftover t3 window so the wait below can only
  // match the re-run's fresh t3 session (the re-run itself is async).
  await page.evaluate(() => {
    const panels = [...document.querySelectorAll('.session-panel')];
    for (const p of panels) {
      const t = p.querySelector('.session-bar-title')?.textContent || '';
      if (t.includes('/t3]')) {
        const btn = p.querySelector('.session-bar-close');
        if (btn) btn.click();
      }
    }
  });
  await sleep(400);
  // DOM clicks (not coordinate): overlapping session windows would
  // intercept the mouse at the plan strip's button positions.
  const clickPlanHeaderBtn = (label) => page.evaluate((lbl) => {
    const btns = [...document.querySelectorAll('button.plan-strip-btn')];
    const b = btns.find(x => (x.textContent || '').includes(lbl));
    if (b && !b.disabled) { b.click(); return true; }
    return false;
  }, label);
  const closePlanWindow = () => page.evaluate(() => {
    const bar = document.querySelector('.plan-panel .session-bar.plan-bar');
    const btn = bar && bar.querySelector('.session-bar-close');
    if (btn) { btn.click(); return true; }
    return false;
  });
  const reopenPlanViaStatusBar = async () => {
    await page.evaluate(() => {
      const b = [...document.querySelectorAll('button')].find(e => /^\[Plan: /.test((e.textContent || '').trim()));
      if (b) b.click();
    });
    await page.waitForFunction(() => {
      return document.querySelectorAll('.plan-page').length === 1;
    }, { timeout: 10000 });
    await sleep(400);
  };
  assert(await clickPlanHeaderBtn('Run'), 're-Run button');
  await page.waitForFunction(() => {
    return [...document.querySelectorAll('.session-panel')].some(p =>
      (p.querySelector('.session-bar-title')?.textContent || '').includes('/t3]'));
  }, { timeout: 30000 });
  await sleep(400);
  await shot(page, '05d-stop-before.png');
  assert(await clickPlanHeaderBtn('Stop'), 'Stop button');
  await page.waitForFunction(() => !!document.querySelector('.plan-run-dot-stopped'), { timeout: 10000 });
  await sleep(500);
  const t3Windows = await page.$$eval('.session-panel', panels =>
    panels.filter(p => (p.querySelector('.session-bar-title')?.textContent || '').includes('/t3]')).length);
  assert(t3Windows === 0, 't3 session window closed after Stop, got: ' + t3Windows);
  await shot(page, '05e-stop-after.png');
  console.log("PASS: Plan Stop closed the run's node session windows (badge Stopped)");

  // ── 8e. Plan window close under a TERMINAL run (P35, user report) ──
  // The plan is Stopped (8b). Clicking node t1 RESUMES its session from
  // disk (window opens for review). Closing the plan window must close
  // that node session window too — this is the exact case the user
  // reported as still broken: sessions open under a non-active run.
  await clickNode(page, 't1');
  await page.waitForFunction(() => {
    return [...document.querySelectorAll('.session-panel')].some(p =>
      (p.querySelector('.session-bar-title')?.textContent || '').includes('/t1]'));
  }, { timeout: 30000 });
  await sleep(400);
  await shot(page, '05e1-terminal-node-open.png');
  assert(await closePlanWindow(), 'plan window close button clicked (terminal run)');
  await page.waitForFunction(() => {
    return document.querySelectorAll('.plan-page').length === 0;
  }, { timeout: 10000 });
  await sleep(800);
  const terminalCloseAfter = await page.evaluate(() => {
    const planCount = document.querySelectorAll('.plan-page').length;
    const t1Count = [...document.querySelectorAll('.session-panel')].filter(p =>
      (p.querySelector('.session-bar-title')?.textContent || '').includes('/t1]')).length;
    return { planCount, t1Count };
  });
  assert(terminalCloseAfter.planCount === 0, 'plan window closed (terminal run), got: ' + terminalCloseAfter.planCount);
  assert(terminalCloseAfter.t1Count === 0, 'resumed node session window closed after plan window close, got: ' + terminalCloseAfter.t1Count);
  await shot(page, '05e2-terminal-node-closed.png');
  console.log('PASS: plan window close under a Stopped run closed the resumed node session window (P35)');

  // Reopen the plan for the next phase.
  await reopenPlanViaStatusBar();

  // ── 8d. Closing the PLAN window cascades to its node sessions (P35) ─
  // Re-run the plan (t3 hangs again): the t3 node session window is
  // open below the plan window. Closing the plan window must STOP the
  // run and close the t3 session window too — no respawn afterwards.
  execSync('rm -f /tmp/alayaface-fakecore-hang-once-*.marker');
  assert(await clickPlanHeaderBtn('Run'), 'plan-close re-Run button');
  await page.waitForFunction(() => {
    return [...document.querySelectorAll('.session-panel')].some(p =>
      (p.querySelector('.session-bar-title')?.textContent || '').includes('/t3]'));
  }, { timeout: 30000 });
  await sleep(400);
  await shot(page, '05f1-plan-close-before.png');
  assert(await closePlanWindow(), 'plan window close button clicked');
  await page.waitForFunction(() => {
    return document.querySelectorAll('.plan-page').length === 0;
  }, { timeout: 10000 });
  await sleep(1500); // let the cascade settle; assert nothing respawns
  const planCloseAfter = await page.evaluate(() => {
    const planCount = document.querySelectorAll('.plan-page').length;
    const t3Count = [...document.querySelectorAll('.session-panel')].filter(p =>
      (p.querySelector('.session-bar-title')?.textContent || '').includes('/t3]')).length;
    return { planCount, t3Count };
  });
  assert(planCloseAfter.planCount === 0, 'plan window closed, got: ' + planCloseAfter.planCount);
  assert(planCloseAfter.t3Count === 0, 'node session window closed after plan window close (no respawn), got: ' + planCloseAfter.t3Count);
  await shot(page, '05f2-plan-close-after.png');
  console.log('PASS: closing the plan window cascaded: node session windows closed (P35)');

  // Reopen the plan through the origin session's [Plan: …] status-bar
  // link (the only way plans reopen — P30) for the 8c cascade below.
  await reopenPlanViaStatusBar();

  // ── 8c. Closing the ORIGIN session cascades to its children (P34) ──
  // Re-run the plan (t3 hangs again): origin session + plan window + t3
  // session window are all open. Closing the origin session must STOP
  // the run and close the plan window AND the t3 session window — no
  // respawn afterwards. (Remove the hang marker again: the previous
  // hung t3 re-wrote it, which would make t3 succeed instantly here.)
  execSync('rm -f /tmp/alayaface-fakecore-hang-once-*.marker');
  assert(await clickPlanHeaderBtn('Run'), 'cascade re-Run button');
  await page.waitForFunction(() => {
    return [...document.querySelectorAll('.session-panel')].some(p =>
      (p.querySelector('.session-bar-title')?.textContent || '').includes('/t3]'));
  }, { timeout: 30000 });
  await sleep(400);
  await shot(page, '05f-cascade-before.png');
  // Close the ORIGIN session: the plain "Session N" window that created
  // the plan (node sessions carry a "[Plan · ..." badge — exclude them).
  const closedOrigin = await page.evaluate(() => {
    const panels = [...document.querySelectorAll('.session-panel')];
    for (const p of panels) {
      const t = p.querySelector('.session-bar-title')?.textContent || '';
      if (!t.includes('[Plan ·') && /Session \d+/.test(t)) {
        const btn = p.querySelector('.session-bar-close');
        if (btn) { btn.click(); return true; }
      }
    }
    return false;
  });
  assert(closedOrigin, 'origin session close button clicked');
  await page.waitForFunction(() => {
    return document.querySelectorAll('.plan-page').length === 0;
  }, { timeout: 10000 });
  await sleep(1500); // let the cascade settle; assert nothing respawns
  const cascadeAfter = await page.evaluate(() => {
    const planCount = document.querySelectorAll('.plan-page').length;
    const t3Count = [...document.querySelectorAll('.session-panel')].filter(p =>
      (p.querySelector('.session-bar-title')?.textContent || '').includes('/t3]')).length;
    return { planCount, t3Count };
  });
  assert(cascadeAfter.planCount === 0, 'plan window closed after origin session close, got: ' + cascadeAfter.planCount);
  assert(cascadeAfter.t3Count === 0, 'node session window closed after origin session close (no respawn), got: ' + cascadeAfter.t3Count);
  await shot(page, '05g-cascade-after.png');
  console.log('PASS: closing the origin session cascaded: plan window + node session windows closed (P34)');

  // ── 9. No Plans manager in the system menu (P30: plans are reopened
  // via the session's [Plan: …] status-bar link; the standalone manager
  // entry was removed).
  await page.click('.global-menu-btn');
  await waitFor('.global-menu-panel');
  const menuItems = await page.$$eval('.global-menu-item', els => els.map(e => e.textContent));
  assert(!menuItems.some(t => t.includes('Plans')), 'no "Plans" item in the system menu, got: ' + JSON.stringify(menuItems));
  console.log('PASS: system menu has no Plans entry (plans reopen via [Plan: …] status-bar links)');
  await page.click('.global-menu-btn'); // close the menu
  await sleep(200);

  // ── 9. Auto-open is immediate for live plans (R6 playback-aware) ──
  // A LIVE plan message auto-opens right away (no settle delay), even if
  // a follow-up message arrives shortly after. History replays (resumed
  // sessions) are suppressed — covered by the dedicated verification.
  await page.click('.global-menu-btn');
  await waitFor('.global-menu-panel', 10000);
  await clickByText('.global-menu-item', 'New Session');
  await waitFor('.session-panel', 10000);
  await sleep(600);
  const beforeSettleCount = await page.$$eval('.plan-page', els => els.length);
  await page.evaluate(() => {
    const panels = [...document.querySelectorAll('.session-panel')];
    let best = -1;
    for (const p of panels) { const m = (p.querySelector('.session-bar-title')?.textContent || '').match(/Session (\d+)/); if (m) best = Math.max(best, parseInt(m[1], 10)); }
    for (const p of panels) {
      const m = (p.querySelector('.session-bar-title')?.textContent || '').match(/Session (\d+)/);
      if (!m || parseInt(m[1], 10) !== best) continue;
      const ta = p.querySelector('textarea.input-text');
      if (ta) ta.focus();
    }
  });
  await page.keyboard.type('create a plan', { delay: 2 });
  await page.keyboard.press('Enter');
  await sleep(400);
  await page.keyboard.type('and then follow up', { delay: 2 });
  await page.keyboard.press('Enter');
  await sleep(2500);
  const settlePlanCount = await page.$$eval('.plan-page', els => els.length);
  assert(settlePlanCount === beforeSettleCount + 1, 'live plan auto-opened immediately (before=' + beforeSettleCount + ', after=' + settlePlanCount + ')');
  console.log('PASS: live plan auto-opens immediately; follow-up message does not suppress it');

  console.log('\nALL PASS ✅');
  console.log(KEEP_ARTIFACTS ? `artifacts: ${tmp}` : 'artifacts: <removed on exit — set ALAYAFACE_KEEP_ARTIFACTS=1 to keep screenshots>');
  console.log('screenshots:');
  for (const s of shots) console.log('  ' + s);
} finally {
  if (browser) await browser.close().catch(() => {});
  killServer();
  removeTmp();
}

// ── helpers ─────────────────────────────────────────────────────────

async function clickNode(page, nodeId) {
  // DOM click (not pixel-coordinate): overlapping session windows would
  // intercept the mouse at the node's screen position.
  await page.evaluate((id) => {
    const nodes = [...document.querySelectorAll('.plan-node')];
    const n = nodes.find(el => el.querySelector('.plan-node-id')?.textContent === id);
    if (n) n.click();
  }, nodeId);
}

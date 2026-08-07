#!/usr/bin/env node
// Plan Mode E2E — headless Chrome + Go backend + fakecore (no real model).
//
// Flow:
//   1. build fakecore + Go server (fresh HOME), start both
//   2. Chrome headless → ⚙ → New Plan Session → send a prompt
//   3. fakecore answers with a fenced plan JSON → Create Plan offer
//   4. Create Plan → Plan window DAG → set concurrency → Run
//   5. t1 ok → t2 fails once (marker) → auto-retry → ok → t3 ok → Completed
//   6. Node detail: t2 shows failure history + ≥2 attempt sessions
//   7. Click t1 node → its session window activates and shows the reply
//
// Screenshots land in the artifact dir; ALL PASS printed on success.

import puppeteer from 'puppeteer-core';
import { execSync, spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, writeFileSync, existsSync, readdirSync, readFileSync } from 'node:fs';
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
  // created; the app also auto-creates a plain session at startup).
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

  // ── 5. Plan window → Run ──────────────────────────────────────────
  const nodeIds = await page.$$eval('.plan-node-id', els => els.map(e => e.textContent));
  assert(nodeIds.includes('t1') && nodeIds.includes('t2') && nodeIds.includes('t3'),
    'DAG nodes t1/t2/t3, got: ' + JSON.stringify(nodeIds));
  console.log('PASS: Plan window with DAG nodes', JSON.stringify(nodeIds));

  // Concurrency override (exercises parseConcurrency path).
  await page.type('.plan-header-concurrency', '1', { delay: 5 });
  assert(await clickByText('button.plan-header-btn', 'Run'), 'Run button');

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
  // ~/.alayaface/plans/<planId>/work as their cwd (created by backend).
  const plansRoot = path.join(home, '.alayaface', 'plans');
  const workDirs = readdirSync(plansRoot)
    .filter(n => n.startsWith('e2e-demo-'))
    .map(n => path.join(plansRoot, n, 'work'))
    .filter(existsSync);
  assert(workDirs.length >= 1, 'plan work dir exists, found: ' + JSON.stringify(workDirs));
  console.log('PASS: plan work dir isolated:', workDirs[0]);

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
  const runJson = readdirSync(plansRoot)
    .filter(n => n.startsWith('e2e-demo-') && n.endsWith('.run.json'))
    .map(n => path.join(plansRoot, n))
    .filter(existsSync)
    .map(f => JSON.parse(readFileSync(f, 'utf8')))[0];
  assert(runJson, 'run.json exists for the e2e plan');
  console.log('run.json status:', runJson.status, 'concurrency:', runJson.concurrency);
  const t2n = runJson.nodes && runJson.nodes.t2;
  assert(t2n && t2n.attempts === 1, 'run.json: t2 attempted once (auto-retry), got: ' + JSON.stringify(t2n));
  assert(t2n.status === 'succeeded', 'run.json: t2 succeeded after retry, got: ' + t2n.status);
  assert(runJson.nodes.t1.status === 'succeeded' && runJson.nodes.t3.status === 'succeeded',
    'run.json: t1/t3 succeeded, got: ' + JSON.stringify([runJson.nodes.t1 && runJson.nodes.t1.status, runJson.nodes.t3 && runJson.nodes.t3.status]));
  console.log('PASS: t2 failed once → auto-retry (run.json attempts=1):', JSON.stringify(t2n));

  // ── 7. Click t1 node → its session window resumes ─────────────────
  // R4: succeeded node windows are closed — clicking the node RESUMES
  // its on-disk session (history is kept by real alayacore; fakecore
  // does not replay history, so we assert the resume succeeded: window
  // with the /t1 badge and no plan error — not message content).
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

  // ── 7b. Node ↔ session connection curve ───────────────────────────
  // Focusing a plan-node session raises the plan window to the SECOND
  // layer (session z = plan z + 1) and bridge.js draws a bezier overlay.
  const connState = async () => {
    const st = await page.evaluate(() => {
      const svg = document.querySelector('.node-connection-overlay');
      const active = document.querySelector('.session-panel.session-panel-active');
      const plan = [...document.querySelectorAll('.plan-panel')]
        .find(p => [...p.querySelectorAll('.plan-node-id')].some(e => e.textContent === 't1'));
      return {
        svgVisible: svg ? getComputedStyle(svg).display !== 'none' : false,
        pathD: svg ? (svg.querySelector('path')?.getAttribute('d') || '') : '',
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
    console.log('PASS: ' + label + ' (session z=' + st.sessionZ + ', plan z=' + st.planZ + ')');
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
    console.log('PASS: ' + label + ' — session reopened (' + activeTitle + '), no error');
    await assertConnection(label + ' — curve back after resume');
  };

  await closeT1Session();
  await sleep(500);
  const hiddenAfterClose = await page.evaluate(() => {
    const svg = document.querySelector('.node-connection-overlay');
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
  // intercept the mouse at the plan header's button positions.
  const clickPlanHeaderBtn = (label) => page.evaluate((lbl) => {
    const btns = [...document.querySelectorAll('button.plan-header-btn')];
    const b = btns.find(x => (x.textContent || '').includes(lbl));
    if (b && !b.disabled) { b.click(); return true; }
    return false;
  }, label);
  assert(await clickPlanHeaderBtn('Run'), 're-Run button');
  await page.waitForFunction(() => {
    return [...document.querySelectorAll('.session-panel')].some(p =>
      (p.querySelector('.session-bar-title')?.textContent || '').includes('/t3]'));
  }, { timeout: 30000 });
  await sleep(400);
  await shot(page, '05d-stop-before.png');
  assert(await clickPlanHeaderBtn('Stop'), 'Stop button');
  await page.waitForFunction(() => !!document.querySelector('.plan-run-badge-stopped'), { timeout: 10000 });
  await sleep(500);
  const t3Windows = await page.$$eval('.session-panel', panels =>
    panels.filter(p => (p.querySelector('.session-bar-title')?.textContent || '').includes('/t3]')).length);
  assert(t3Windows === 0, 't3 session window closed after Stop, got: ' + t3Windows);
  await shot(page, '05e-stop-after.png');
  console.log("PASS: Plan Stop closed the run's node session windows (badge Stopped)");

  // ── 9. Plans manager: Saved fuzzy filter + Browse-tab file import ──
  // Write plan JSONs at the fake home root (the Browse tab starts there):
  // one WITH the type marker (imports fine), one WITHOUT it (P26: no
  // backward compatibility — must be rejected with an error in the
  // manager, no window opens).
  const importedName = 'imported-via-browse';
  const importedPlan = {
    type: 'alayaface-plan',
    schema_version: 1,
    name: 'Imported Via Browse',
    goal: 'Plan imported from a file via the Browse tab',
    concurrency: 1,
    default_max_attempts: 2,
    tasks: [{ id: 'n1', title: 'Only Task', prompt: 'do the thing', depends_on: [], max_attempts: 2 }]
  };
  writeFileSync(path.join(home, importedName + '.json'), JSON.stringify(importedPlan, null, 2));
  const legacyName = 'legacy-no-marker';
  const legacyPlan = {
    schema_version: 1,
    name: 'Legacy No Marker',
    goal: 'must be rejected',
    concurrency: 1,
    default_max_attempts: 2,
    tasks: [{ id: 'n1', title: 'Only Task', prompt: 'do the thing', depends_on: [], max_attempts: 2 }]
  };
  writeFileSync(path.join(home, legacyName + '.json'), JSON.stringify(legacyPlan, null, 2));

  // Open ⚙ → Plans (Saved tab default).
  await page.click('.global-menu-btn');
  await waitFor('.global-menu-panel');
  assert(await clickByText('.global-menu-item', 'Plans'), 'Plans menu item');
  await waitFor('.plan-tab', 10000);
  await sleep(500);
  await shot(page, '06-plans-manager-saved.png');

  // Saved tab: the plan created earlier via Create Plan must be listed.
  const savedNames = await page.$$eval('.sel-page-item-name', els => els.map(e => e.textContent));
  assert(savedNames.some(n => n.startsWith('e2e-demo-')), 'Saved tab lists the created plan, got: ' + JSON.stringify(savedNames));

  // Saved fuzzy filter: unmatched term → "No plans match".
  await page.type('.plan-filter-row input', 'zzz-no-such-plan', { delay: 1 });
  await sleep(200);
  const savedStatuses = await page.$$eval('.sel-page-status', els => els.map(e => e.textContent));
  assert(savedStatuses.some(s => s.includes('No plans match')), 'Saved filter no-match status, got: ' + JSON.stringify(savedStatuses));
  await page.evaluate(() => {
    const i = document.querySelector('.plan-filter-row input');
    if (i) { i.value = ''; i.dispatchEvent(new Event('input', { bubbles: true })); }
  });
  await sleep(200);
  console.log('PASS: Saved tab lists plans and fuzzy-filters');

  // Switch to Browse tab: file browser rooted at home dir.
  assert(await clickByText('.plan-tab', 'Browse'), 'Browse tab button');
  await waitFor('#fp-page-input-plan', 10000);
  await sleep(700);
  await shot(page, '07-plans-manager-browse.png');
  const browseEntries = await page.$$eval('.fp-page-item-name', els => els.map(e => e.textContent));
  assert(browseEntries.includes(importedName + '.json'), 'Browse tab lists the importable plan, got: ' + JSON.stringify(browseEntries));

  // Browser fuzzy filter: unmatched → "No files found".
  await page.type('#fp-page-input-plan', 'zzz-nope', { delay: 1 });
  await sleep(250);
  const browseStatuses = await page.$$eval('.fp-page-status', els => els.map(e => e.textContent));
  assert(browseStatuses.some(s => s.includes('No files found')), 'Browse filter no-match status, got: ' + JSON.stringify(browseStatuses));
  // Clear the filter suffix (back to "<home>/") so all entries show again.
  await page.evaluate(() => {
    const i = document.querySelector('#fp-page-input-plan');
    if (i) { i.value = i.value.slice(0, i.value.length - 8); i.dispatchEvent(new Event('input', { bubbles: true })); }
  });
  await sleep(250);

  // ── 9b. A plan file WITHOUT the type marker is rejected (P26: no
  // backward compatibility) — the error shows in the Plans manager and
  // no plan window opens.
  await page.evaluate((name) => {
    const items = [...document.querySelectorAll('.fp-page-item')];
    const it = items.find(el => el.querySelector('.fp-page-item-name')?.textContent === name + '.json');
    if (it) it.click();
  }, legacyName);
  await sleep(700);
  const legacyErr = await page.$$eval('.sel-page-status-error', els => els.map(e => e.textContent));
  assert(legacyErr.some(t => t.includes('type')), 'legacy file without the marker rejected in the manager, got: ' + JSON.stringify(legacyErr));
  console.log('PASS: plan file without the type marker is rejected (no backward compat):', JSON.stringify(legacyErr));

  // Click the plan file (WITH marker) → imported → a NEW plan window with
  // node n1 opens.
  await page.evaluate((name) => {
    const items = [...document.querySelectorAll('.fp-page-item')];
    const it = items.find(el => el.querySelector('.fp-page-item-name')?.textContent === name + '.json');
    if (it) it.click();
  }, importedName);
  await page.waitForFunction(() => {
    const ids = [...document.querySelectorAll('.plan-node-id')].map(e => e.textContent);
    return ids.includes('n1');
  }, { timeout: 30000 });
  await sleep(800);
  await shot(page, '08-imported-plan-window.png');
  console.log('PASS: Browse tab imported the plan file (new Plan window with node n1)');

  // ── 9. Auto-open is last-message-only (R6 settle rule) ────────────
  // A plan message followed within the settle window by another message
  // must NOT auto-open a window; the message instead shows a manual
  // "Open plan" button.
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
  await sleep(3500);
  const settlePlanCount = await page.$$eval('.plan-page', els => els.length);
  const openBtnVisible = await page.$$eval('.session-panel .plan-open-btn', els => els.length);
  assert(settlePlanCount === beforeSettleCount, 'plan followed by another message must not auto-open (before=' + beforeSettleCount + ', after=' + settlePlanCount + ')');
  assert(openBtnVisible >= 1, 'suppressed plan message shows a manual "Open plan" button');
  console.log('PASS: auto-open is last-message-only; suppressed plan shows "Open plan"');

  console.log('\nALL PASS ✅');
  console.log('artifacts:', tmp);
  console.log('screenshots:');
  for (const s of shots) console.log('  ' + s);
} finally {
  if (browser) await browser.close().catch(() => {});
  server.kill('SIGTERM');
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

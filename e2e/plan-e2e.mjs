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
import { mkdtempSync, writeFileSync, existsSync, readdirSync } from 'node:fs';
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
  assert(await clickByText('.global-menu-item', 'New Plan Session'), 'New Plan Session menu item');

  // Session window with [Plan] title appears.
  await waitFor('.session-panel');
  await sleep(600);
  const planTitles = await page.$$eval('.session-bar-title', els => els.map(e => e.textContent));
  assert(planTitles.some(t => t.includes('[Plan]')), 'plan session title prefix, got: ' + JSON.stringify(planTitles));

  // Send the user prompt INTO the [Plan] session window (the app also
  // auto-creates a plain session at startup, so there are two windows).
  const planPanel = await page.$$eval('.session-panel', panels => {
    for (const p of panels) {
      const t = p.querySelector('.session-bar-title')?.textContent || '';
      if (t.includes('[Plan]')) {
        const ta = p.querySelector('textarea.input-text');
        const btn = p.querySelector('.send-btn');
        return { has: true, title: t, ta: !!ta, btn: !!btn };
      }
    }
    return { has: false };
  });
  console.log('plan panel:', JSON.stringify(planPanel));
  assert(planPanel.has, 'plan session window not found');

  await page.evaluate(() => {
    const panels = [...document.querySelectorAll('.session-panel')];
    for (const p of panels) {
      const t = p.querySelector('.session-bar-title')?.textContent || '';
      if (!t.includes('[Plan]')) continue;
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

  // fakecore answers with the fenced plan JSON → Create Plan offer.
  await waitFor('.plan-offer-btn', 30000);
  await shot(page, '01-create-plan-offer.png');
  console.log('PASS: Create Plan offer appeared');

  // ── 5. Create Plan → Plan window → Run ────────────────────────────
  await page.click('.plan-offer-btn');
  await waitFor('.plan-page', 30000);
  await sleep(800);
  await shot(page, '02-plan-window.png');
  const nodeIds = await page.$$eval('.plan-node-id', els => els.map(e => e.textContent));
  assert(nodeIds.includes('t1') && nodeIds.includes('t2') && nodeIds.includes('t3'),
    'DAG nodes t1/t2/t3, got: ' + JSON.stringify(nodeIds));
  console.log('PASS: Plan window with DAG nodes', JSON.stringify(nodeIds));

  // Concurrency override (exercises parseConcurrency path).
  await page.type('.plan-header-concurrency', '1', { delay: 5 });
  assert(await clickByText('button.plan-header-btn', 'Run'), 'Run button');

  // Wait for the run to complete: t2 fails once → auto-retry → all ok.
  await waitFor('.plan-run-badge-completed', E2E_TIMEOUT);
  await shot(page, '03-completed.png');
  const succ = await page.$$eval('.plan-node-succeeded', els => els.map(e => e.querySelector('.plan-node-id')?.textContent));
  assert(succ.length === 3, 'all 3 nodes Succeeded, got: ' + JSON.stringify(succ));
  console.log('PASS: run completed, nodes succeeded:', JSON.stringify(succ));

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
  // (Succeeded nodes open their session on click — the detail panel with
  // failure history is for nodes without a live/restorable session — so
  // the retry trace is asserted via the run log instead.)
  await page.click('.plan-bar');
  await sleep(300);
  const logText = await page.$eval('.plan-run-log', el => el.textContent).catch(() => '');
  console.log('RUN LOG FULL:\n' + logText);
  assert(logText.includes('t2'), 'run log mentions t2, got: ' + logText.slice(0, 300));
  assert(logText.includes('waiting'), 'run log shows the backoff (waiting) after the t2 failure, got: ' + logText.slice(0, 400));
  // attempts counts FAILURES: t2 shows [1] (failed once, then retried ok).
  assert(logText.includes('t2 [1'), 'run log shows attempt 1 for t2 (auto-retry), got: ' + logText.slice(0, 400));
  // t3 HUNG on its first attempt: the 5s task timeout failed it and the
  // auto-retry succeeded (attempts [1] again, waiting appears for t3).
  assert(logText.includes('t3 [1'), 'run log shows attempt 1 for t3 (timeout → auto-retry), got: ' + logText.slice(0, 400));
  assert((logText.match(/t3 \[1[^]*?waiting/g) || []).length >= 1, 'run log shows t3 waiting after timeout, got: ' + logText.slice(0, 500));
  await shot(page, '04-run-log.png');
  console.log('PASS: t2 failed once → auto-retry (run log):', logText.split('\n').filter(Boolean).join(' | '));

  // ── 7. Click t1 node → its session window activates with the reply ─
  // DOM click (not pixel-coordinate click): overlapping session windows
  // would otherwise intercept the mouse at the node's screen position.
  await clickNode(page, 't1');
  await sleep(800);
  const active = await page.evaluate(() => {
    const p = document.querySelector('.session-panel.session-panel-active .session-bar-title');
    return p ? p.textContent : '';
  });
  assert(active.includes('/t1'), 't1 session activated, got: ' + active);
  const texts = await page.evaluate(() => {
    const p = document.querySelector('.session-panel.session-panel-active');
    return p ? [...p.querySelectorAll('.message-content')].map(e => e.textContent) : [];
  });
  if (!texts.some(t => t.includes('Hello'))) {
    // Debug dump: what does the active session window actually contain?
    const html = await page.evaluate(() => {
      const p = document.querySelector('.session-panel.session-panel-active');
      return p ? p.innerHTML.slice(0, 2500) : '(no active panel)';
    });
    console.log('ACTIVE PANEL HTML:\n' + html);
  }
  assert(texts.some(t => t.includes('Hello')), 't1 session shows the assistant reply, got: ' + JSON.stringify(texts));
  await shot(page, '05-t1-session.png');
  console.log('PASS: t1 node opened its session (activated, reply visible)');

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
  // t2's prompt references {{t1.output}}; when t2's session was created
  // the runner replaced it with t1's recorded output (t1's final AT,
  // which fakecore echoes as "Received prompt: <t1 prompt>"). Click t2
  // and verify its received prompt + reply contain the injected text
  // and that no raw template leaked into the model.
  await clickNode(page, 't2');
  await page.waitForFunction(() => {
    const t = document.querySelector('.session-panel.session-panel-active .session-bar-title')?.textContent || '';
    return t.includes('/t2');
  }, { timeout: 30000 });
  await sleep(600);
  const t2Texts = await page.evaluate(() => {
    const p = document.querySelector('.session-panel.session-panel-active');
    return p ? [...p.querySelectorAll('.message-content')].map(e => e.textContent) : [];
  });
  const t2Joined = t2Texts.join('\n');
  assert(t2Texts.some(t => t.includes('参考上游任务输出')), 't2 prompt carries the injection label, got: ' + JSON.stringify(t2Texts));
  assert(t2Joined.includes('research the topic and summarize findings'), 't2 prompt contains t1\'s recorded output, got: ' + JSON.stringify(t2Texts));
  assert(!t2Joined.includes('{{t1.output}}'), 'raw template fully replaced, got: ' + JSON.stringify(t2Texts));
  await shot(page, '05b-output-injection.png');
  console.log('PASS: {{t1.output}} injected t1\'s recorded output into t2\'s prompt (no raw template)');

  // Restore state for step 8: close t2's session (the connection curve
  // now belongs to t2, so step 8's close-t1 → curve-hidden check needs
  // t2's window gone first).
  await page.evaluate(() => {
    const panels = [...document.querySelectorAll('.session-panel')];
    for (const p of panels) {
      const t = p.querySelector('.session-bar-title')?.textContent || '';
      if (t.includes('/t2]')) {
        const btn = p.querySelector('.session-bar-close');
        if (btn) btn.click();
        break;
      }
    }
  });
  await sleep(500);
  const hiddenAfterT2Close = await page.evaluate(() => {
    const svg = document.querySelector('.node-connection-overlay');
    return svg ? getComputedStyle(svg).display === 'none' : true;
  });
  assert(hiddenAfterT2Close, 'connection curve hidden after t2 closes');
  console.log('PASS: connection curve hidden after closing t2');

  // ── 8. Close/reopen node session (resume regression) ───────────────
  // The node stays bound to the ON-DISK dir id; resume_session hands out
  // a FRESH id that must NOT become the persistent binding (its dir does
  // not exist → "Session directory not found" on the next click). Close
  // the t1 session, click the node again → a NEW session window with the
  // /t1 badge appears and the plan window shows NO error. Do it twice.
  const planErrorCount = async () => {
    const errs = await page.$$eval('.plan-page .sel-page-status-error', els => els.map(e => e.textContent));
    return errs.filter(t => t && t.length > 0).length;
  };
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

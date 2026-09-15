#!/usr/bin/env node
// Session-name E2E (G-series, docs/session-identity.md) — the half that only a
// browser plus a real backend can prove.
//
// What each elm-test cannot see is the PORT: `withLabelSave` returns a `Cmd`, and
// a test cannot name the port inside one (the same limit `UiLayoutTest` lives
// with). So every assertion here reads the FILE BACK FROM DISK, which is also the
// only way to test the three-implementation rule end to end: the client writes a
// document, a backend validates and stores it verbatim, and the reader turns it
// into a row.
//
//   1. a first prompt names the session by itself (SD-G8/G12) — file + title bar
//   2. ✎ Rename commits by ENTER, and the file says `auto:false` (SD-G8)
//   3. Cancel discards — there is deliberately no blur-commit, and this is the
//      assertion that keeps someone from "helpfully" adding one
//   4. a second session is auto-named and never edited: its row is readable,
//      not a hex prefix (the feature's whole point)
//   5. a REAL backend restart (the process is killed, not the page reloaded):
//      both names come back off disk, and Resume puts the name in the title bar
//   6. the filter box keeps matches, sorts them, and says so when nothing does
//   7. a CORRUPT label file is dropped, not guessed at — and the session is
//      still listed (SD-G9: "a session that cannot be named is still a session")
//   8. deleting a session takes the label file with it (the directory IS the
//      ownership boundary; no prune path exists to forget)
//
// Rows are found by `data-session-id` (INV-G3), never by their text: the text is
// a name now, and that is the thing under test.

import puppeteer from 'puppeteer-core';
import { spawn, execSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, existsSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import net from 'node:net';
import { buildGoBinaries } from './build-binaries.mjs';

const ROOT = path.resolve(import.meta.dirname, '..');
const CHROME = '/usr/bin/google-chrome';

const failures = [];
function check(cond, msg) {
  if (cond) { console.log('PASS: ' + msg); return true; }
  console.log('FAIL: ' + msg);
  failures.push(msg);
  return false;
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

const tmp = mkdtempSync(path.join(tmpdir(), 'alayaface-label-e2e-'));
const home = path.join(tmp, 'home');
const artifacts = path.join(tmp, 'shots');
const SESSIONS = path.join(home, '.alayaface', 'sessions');
const KEEP = process.env.ALAYAFACE_KEEP_ARTIFACTS === '1';

const { fakecore, server: serverBin } = buildGoBinaries(ROOT);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const labelPath = (sid) => path.join(SESSIONS, sid, 'session.label.json');
const readLabel = (sid) => JSON.parse(readFileSync(labelPath(sid), 'utf8'));

// Every top-level session dir that looks like a session identity.
function sessionIds() {
  if (!existsSync(SESSIONS)) return [];
  return readdirSync(SESSIONS).filter((d) => {
    if (d.endsWith('.tmp')) return false;
    return existsSync(path.join(SESSIONS, d, 'session.alaya'));
  });
}

let server = null;
async function startServer() {
  const port = await freePort();
  server = spawn(serverBin, [
    '--addr', `127.0.0.1:${port}`,
    '--static', '../src-elm',
    '--alayacore-bin', fakecore,
  ], { cwd: path.join(ROOT, 'src-go'), env: { ...process.env, HOME: home }, stdio: ['ignore', 'pipe', 'pipe'] });
  server.stdout.on('data', (d) => process.stdout.write('[srv] ' + d));
  server.stderr.on('data', (d) => process.stdout.write('[srv!] ' + d));
  await waitPort(port, 30000);
  return `http://127.0.0.1:${port}`;
}

let browser, page;
async function openApp(base) {
  await page.goto(base + '/', { waitUntil: 'networkidle0', timeout: 30000 });
  await page.waitForSelector('.main-content', { timeout: 30000 });
  await sleep(1200); // the startup list_session_dirs + the refs scan
}

async function openGlobalMenu() {
  await page.$eval('.main-content', (el) => el.dispatchEvent(
    new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 30, clientY: 30 })));
  await page.waitForSelector('.global-menu-panel', { timeout: 10000 });
}

async function clickByText(sel, text) {
  for (const h of await page.$$(sel)) {
    const t = await h.evaluate((el) => el.textContent || '');
    if (t.includes(text)) { await h.click(); return true; }
  }
  return false;
}

async function newSession() {
  await openGlobalMenu();
  if (!await clickByText('.global-menu-item', 'New Session')) return false;
  await sleep(250);
  if (!await clickByText('.global-menu-submenu-item', 'Simple')) return false;
  await page.waitForSelector('.session-panel:not(.plan-panel)', { timeout: 20000 });
  await sleep(600);
  return true;
}

// The newest session window's title-bar text.
const barTitle = () => page.$$eval('.session-panel:not(.plan-panel) .session-bar-title',
  (els) => (els.length ? (els[els.length - 1].textContent || '').trim() : ''));

// Type into the newest session window and send.
async function sendPrompt(text) {
  await page.evaluate((t) => {
    const p = [...document.querySelectorAll('.session-panel')].filter((x) => !x.classList.contains('plan-panel')).pop();
    const ta = p && p.querySelector('textarea.input-text');
    if (ta) { ta.value = t; ta.dispatchEvent(new Event('input', { bubbles: true })); }
    const btn = p && p.querySelector('.send-btn');
    if (btn) btn.click();
  }, text);
  await sleep(500);
}

async function openManager() {
  await openGlobalMenu();
  if (!await clickByText('.global-menu-item', 'Session Manager')) throw new Error('Session Manager item missing');
  await page.waitForSelector('.sel-page', { timeout: 10000 });
  await sleep(400);
}

async function closeManager() {
  await page.evaluate(() => {
    const b = document.querySelector('.overlay-card .card-close');
    if (b) b.click();
  });
  await sleep(300);
}

// A row's visible name, by identity (INV-G3 — never the reverse lookup).
const rowName = (sid) => page.evaluate((id) => {
  const row = [...document.querySelectorAll('.sel-page-item')].find((r) => r.dataset.sessionId === id);
  const el = row && row.querySelector('.sel-page-item-name');
  return el ? (el.textContent || '').trim() : null;
}, sid);

const listedRows = () => page.$$eval('.sel-page-item',
  (els) => els.map((e) => e.dataset.sessionId).filter(Boolean));

// Click ✎ Rename on a row, then drive the editor.
async function rename(sid, { text, commit, ...opts }) {
  const opened = await page.evaluate((id) => {
    const row = [...document.querySelectorAll('.sel-page-item')].find((r) => r.dataset.sessionId === id);
    const btn = row && [...row.querySelectorAll('button')].find((b) => (b.textContent || '').includes('Rename'));
    if (btn) { btn.click(); return true; }
    return false;
  }, sid);
  if (!opened) throw new Error('no ✎ Rename button on row ' + sid);
  await page.waitForSelector('#session-rename-input', { timeout: 10000 });
  // The field opens PRE-FILLED (a rename edits a name, it does not restart one),
  // so typing without clearing would append to the old name — which is what the
  // first draft of this script did, and it looked like an encoder bug. Clear
  // through an `input` event, not by assigning `.value`: Elm's model only hears
  // about the field when the event fires.
  await page.evaluate(() => {
    const el = document.querySelector('#session-rename-input');
    el.value = '';
    el.dispatchEvent(new Event('input', { bubbles: true }));
  });
  await page.click('#session-rename-input');
  if (text) await page.type('#session-rename-input', text, { delay: 12 });
  await sleep(150);
  if (opts.shot) await page.screenshot({ path: opts.shot });
  if (commit === 'enter') await page.keyboard.press('Enter');
  else if (commit === 'save') await page.click('[data-rename-commit]');
  else if (commit === 'cancel') await page.evaluate(() => {
    const b = [...document.querySelectorAll('.overlay-card button')].find((x) => (x.textContent || '').trim() === 'Cancel');
    if (b) b.click();
  });
  await sleep(500);
}

const editorOpen = () => page.$$eval('#session-rename-input', (els) => els.length > 0);

process.on('unhandledRejection', (e) => console.log('[reject]', (e && e.message) || String(e)));

let exitCode = 1;
try {
  execSync(`mkdir -p "${artifacts}" "${home}"`);
  let base = await startServer();
  browser = await puppeteer.launch({
    executablePath: CHROME,
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu', '--window-size=1440,920'],
  });
  page = await browser.newPage();
  await page.setViewport({ width: 1440, height: 920 });
  page.on('pageerror', (e) => console.log('[pageerror]', e.message));
  page.on('console', (m) => { if (m.type() === 'error') console.log('[console.error]', m.text()); });

  await openApp(base);

  // ── 1. the first prompt names the session ───────────────────────────
  check(await newSession(), 'session A created');
  const promptA = 'refactor the parser so it stops eating trailing commas';
  await sendPrompt(promptA);
  await page.screenshot({ path: path.join(artifacts, '01-sent.png') });

  let idA = null;
  for (let i = 0; i < 30 && !idA; i++) {
    await sleep(400);
    const ids = sessionIds();
    if (ids.length) idA = ids[0];
  }
  check(!!idA, 'session A exists on disk, id=' + idA);

  // The auto write is the thing no elm-test can see. Poll: it is an RPC.
  let autoFile = null;
  for (let i = 0; i < 30 && !autoFile; i++) {
    await sleep(300);
    if (existsSync(labelPath(idA))) autoFile = readLabel(idA);
  }
  check(!!autoFile, 'the send wrote session.label.json (the port fired — proof only disk gives)');
  check(autoFile && autoFile.auto === true, 'the derived name is marked auto:true, got ' + JSON.stringify(autoFile));
  check(autoFile && autoFile.label === promptA, 'the name IS what the user typed, got ' + (autoFile && autoFile.label));
  check(autoFile && autoFile.v === 1, 'the document carries v:1, got ' + (autoFile && autoFile.v));

  // The derived name reaches the title bar without a reload.
  const titleRe = new RegExp(promptA.slice(0, 20).replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
  check(titleRe.test(await barTitle()), 'the title bar shows the derived name, got: ' + await barTitle());

  // ── 2. rename by ENTER ──────────────────────────────────────────────
  await openManager();
  check(await rowName(idA) === promptA, 'the manager row shows the derived name, got: ' + await rowName(idA));
  await page.screenshot({ path: path.join(artifacts, '02-manager.png') });
  await rename(idA, { text: 'parser commas, hand written', commit: 'enter', shot: path.join(artifacts, '03-editor.png') });
  check(!(await editorOpen()), 'Enter closed the editor (a commit is the END of an interaction)');
  let after = readLabel(idA);
  check(after.label === 'parser commas, hand written', 'the file holds the new name, got: ' + after.label);
  check(after.auto === false, 'a name the user typed is auto:false — nothing may derive over it (SD-G8)');
  check(await rowName(idA) === 'parser commas, hand written', 'the row shows it immediately, got: ' + await rowName(idA));
  await closeManager();
  check((await barTitle()).startsWith('parser commas, hand written'), 'the title bar followed the rename, got: ' + await barTitle());

  // ── 3. Cancel discards (no blur-commit, by design) ──────────────────
  await openManager();
  await rename(idA, { text: 'THIS MUST NOT BE SAVED', commit: 'cancel' });
  check(!(await editorOpen()), 'Cancel closed the editor');
  check(readLabel(idA).label === 'parser commas, hand written',
    'Cancel saved nothing — a blur-commit would have (got ' + readLabel(idA).label + ')');
  await closeManager();

  // ── 4. a session that is never named still says something readable ──
  check(await newSession(), 'session B created');
  const promptB = 'summarise the changelog for 3.2';
  await sendPrompt(promptB);
  let idB = null;
  for (let i = 0; i < 30 && !idB; i++) {
    await sleep(400);
    const others = sessionIds().filter((x) => x !== idA);
    if (others.length) idB = others[0];
  }
  check(!!idB, 'session B exists on disk, id=' + idB);
  let autoB = null;
  for (let i = 0; i < 30 && !autoB; i++) {
    await sleep(300);
    if (existsSync(labelPath(idB))) autoB = readLabel(idB);
  }
  check(!!autoB && autoB.label === promptB && autoB.auto === true, 'B was auto-named without being touched, got ' + JSON.stringify(autoB));
  // (SD-G15 — plan node sessions get no label document — is not re-proved here:
  // it is enforced by the backend refusing a name for anything without a
  // top-level session.alaya, which `label.rs` and `label.go` both test, and the
  // client's own guard is in LabelsTest's autoNameOnFirstPrompt group.)

  // ── 5. a REAL backend restart ───────────────────────────────────────
  // Killing the process is the point: a page reload would keep the same
  // backend, and the feature's claim is that a NAME SURVIVES the store.
  server.kill('SIGKILL');
  await sleep(700);
  base = await startServer();
  await openApp(base);
  await openManager();
  check(await rowName(idA) === 'parser commas, hand written',
    'after a backend restart the row is named from DISK, got: ' + await rowName(idA));
  check(await rowName(idB) === promptB, 'and so is the auto-named one, got: ' + await rowName(idB));

  // Resume A → the name is in the title bar of the resumed window.
  await page.evaluate((id) => {
    const row = [...document.querySelectorAll('.sel-page-item')].find((r) => r.dataset.sessionId === id);
    const btn = [...row.querySelectorAll('button')].find((b) => (b.textContent || '').trim() === 'Resume');
    btn.click();
  }, idA);
  await page.waitForFunction(() => document.querySelectorAll('.session-panel:not(.plan-panel)').length > 0, { timeout: 30000 });
  await sleep(1500);
  check((await barTitle()).startsWith('parser commas, hand written'),
    'the RESUMED window is titled by its name, got: ' + await barTitle());

  // ── 6. the filter box ───────────────────────────────────────────────
  await openManager();
  const all = await listedRows();
  check(all.length === 2, 'both sessions listed before filtering, got ' + JSON.stringify(all));
  await page.type('#session-filter-input', 'summarise', { delay: 12 });
  await sleep(500);
  const only = await listedRows();
  await page.screenshot({ path: path.join(artifacts, '04-filtered.png') });
  check(only.length === 1 && only[0] === idB, 'filtering by name keeps exactly the match, got ' + JSON.stringify(only));
  await page.evaluate(() => { document.querySelector('#session-filter-input').value = ''; });
  await page.type('#session-filter-input', 'zzzznomatch', { delay: 5 });
  await sleep(500);
  check((await listedRows()).length === 0, 'a term that matches nothing lists nothing');
  check(await page.$$eval('.sel-page-status', (els) => els.map((e) => e.textContent || '').join(' '))
    .then((t) => t.includes('No session matches that filter')),
    'the empty result says WHY, not "no saved sessions"');
  await page.evaluate(() => {
    const el = document.querySelector('#session-filter-input');
    el.value = '';
    el.dispatchEvent(new Event('input', { bubbles: true }));
  });
  await sleep(400);
  check((await listedRows()).length === 2, 'clearing the filter brings the board back');
  await closeManager();

  // ── 7. a corrupt label is dropped, not guessed (SD-G9) ──────────────
  writeFileSync(labelPath(idB), '{ this is not json');
  // SD-G9 is a RULE ABOUT READING, so it needs a reader that has never seen the
  // good value: this process already believes the name (and a listing fills gaps,
  // it does not overwrite — `foldListing`), so reloading the page is what makes
  // the corrupt file the only source. Without the reload this assertion would
  // pass for the wrong reason forever.
  await page.goto(base + '/', { waitUntil: 'networkidle0', timeout: 30000 });
  await sleep(1500);
  await openManager();
  const bRow = await rowName(idB);
  check(bRow === idB.slice(0, 8), 'an unreadable name falls back to the id prefix, got: ' + JSON.stringify(bRow));
  check((await listedRows()).includes(idB), 'and the session is STILL listed — a name it cannot read never hides a session');
  await closeManager();

  // ── 8. deleting the session deletes the name ────────────────────────
  await openManager();
  await page.evaluate((id) => {
    const row = [...document.querySelectorAll('.sel-page-item')].find((r) => r.dataset.sessionId === id);
    const btn = [...row.querySelectorAll('button')].find((b) => (b.textContent || '').trim() === 'Delete');
    btn.click();
  }, idB);
  await sleep(1500);
  await page.evaluate(() => {
    const b = [...document.querySelectorAll('.overlay-card button, .confirm-page-buttons button')]
      .find((x) => /Confirm|Yes|Delete/.test((x.textContent || '').trim()) && (x.textContent || '').trim() !== 'Delete');
    if (b) b.click();
  });
  await sleep(2000);
  check(!existsSync(path.join(SESSIONS, idB)), 'deleting B took its directory, so the label went with it (no prune path to forget)');
  check(existsSync(labelPath(idA)) && existsSync(path.join(SESSIONS, idA)), 'A and its name are untouched by the delete');
  await page.screenshot({ path: path.join(artifacts, '02-final.png') });
  exitCode = failures.length ? 1 : 0;
} catch (e) {
  console.log('[fatal]', (e && e.stack) || String(e));
  exitCode = 1;
} finally {
  if (browser) await browser.close().catch(() => {});
  try { if (server) server.kill('SIGKILL'); } catch {}
  console.log('\n' + (failures.length ? failures.length + ' FAILURE(S):\n  ' + failures.join('\n  ') : 'ALL PASS ✅'));
  if (KEEP) console.log('artifacts: ' + tmp + ' (kept)');
  else { try { rmSync(tmp, { recursive: true, force: true }); } catch {} }
  process.exit(exitCode);
}

#!/usr/bin/env node
// Why-a-session-ended E2E — headless Chrome + Go backend + a wrapped fakecore.
//
// Covers the chain that carries a REASON to the user, which no unit test can:
//
//   alayacore stderr → the backend's StderrTail → core-status.message →
//   Session.Handlers.appendEndNotice → the transcript.
//
// Phases:
//   A. a core that dies at startup with a reason on stderr and NOTHING on
//      stdout — what a v12 core does with a v11 session file. The window must
//      show the reason IN THE TRANSCRIPT: the title-bar status line was dropped
//      (7c99f83) and `SessionState.statusMsg` has no reader, so a reason that
//      is not a message is a reason nobody sees.
//   B. a healthy core killed under a live session (SIGKILL, so no stderr at
//      all). The plain pipe-death line must appear.
//   C. one death, one line: the client's plan runner fails its node on every
//      `connected:false` it is told about, so a second announcement of the same
//      death is both a duplicated transcript line and a double-reported failure.
//
// The wrapper script is how one server can produce both cores: a flag file
// decides whether it dies like a refused session file or execs the real fake.
import puppeteer from 'puppeteer-core';
import { execSync, spawn } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import net from 'node:net';

const ROOT = path.resolve(import.meta.dirname, '..');
const CHROME = '/usr/bin/google-chrome';
const REASON = 'Error: failed to load session: session file version mismatch: got 11, expected 12';

function assert(cond, msg) {
  if (!cond) throw new Error('ASSERT FAILED: ' + msg);
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitPort(port, ms = 25000) {
  const deadline = Date.now() + ms;
  for (;;) {
    const ok = await new Promise((res) => {
      const s = net.connect(port, '127.0.0.1');
      s.on('connect', () => { s.destroy(); res(true); });
      s.on('error', () => { s.destroy(); res(false); });
    });
    if (ok) return;
    assert(Date.now() < deadline, 'the backend never came up');
    await sleep(100);
  }
}

const tmp = mkdtempSync(path.join(tmpdir(), 'alayaface-endreason-'));
const home = path.join(tmp, 'home');
const flag = path.join(tmp, 'die-now');
const SRCGO = path.join(ROOT, 'src-go');
execSync(`mkdir -p "${home}"`);
// Same build step as the other suites (go build is incremental).
execSync('go build -o ./bin/fakecore ./internal/fakecore && go build -o ./bin/alayaface-server ./cmd/alayaface-server', { cwd: SRCGO });

const wrapper = path.join(tmp, 'alayacore');
writeFileSync(wrapper, `#!/bin/sh
if [ -f "${flag}" ]; then
  printf '%s\\n' '${REASON}' >&2
  exit 1
fi
exec "${SRCGO}/bin/fakecore" "$@"
`);
execSync(`chmod +x "${wrapper}"`);

const port = 8790 + (process.pid % 100);
const server = spawn(path.join(SRCGO, 'bin/alayaface-server'),
  ['--addr', `127.0.0.1:${port}`, '--static', path.join(ROOT, 'src-elm'), '--config-path', home],
  { stdio: ['ignore', 'ignore', 'ignore'], env: { ...process.env, HOME: home, ALAYACORE_BIN: wrapper } });
await waitPort(port);

const browser = await puppeteer.launch({
  executablePath: CHROME, headless: 'new',
  args: ['--no-sandbox', '--disable-dev-shm-usage', `--user-data-dir=${path.join(tmp, 'profile')}`],
});
const page = await browser.newPage();
page.on('console', (m) => { if (m.text().includes('ERROR') || m.text().includes('Uncaught')) console.log('  [console]', m.text()); });
await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: 'domcontentloaded' });
await page.waitForSelector('.main-content', { timeout: 30000 });

async function openGlobalMenu() {
  await page.$eval('.main-content', (el) => el.dispatchEvent(
    new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 20, clientY: 20 })));
  await page.waitForSelector('.global-menu-panel', { visible: true, timeout: 10000 });
}

/** One session window through the menu (the same path solo-e2e uses). */
async function createSession(label) {
  const before = await page.evaluate(() => document.querySelectorAll('.session-panel').length);
  await openGlobalMenu();
  const items = await page.$$('.global-menu-item');
  let clicked = false;
  for (const h of items) {
    if ((await h.evaluate((el) => el.textContent || '')).includes('New Session')) { await h.click(); clicked = true; break; }
  }
  assert(clicked, `${label}: no "New Session" menu item`);
  await sleep(400);
  const subs = await page.$$('.global-menu-submenu-item');
  assert(subs.length > 0, `${label}: the preset flyout has no items`);
  await subs[0].click();
  await page.waitForFunction((n) => document.querySelectorAll('.session-panel').length > n,
    { timeout: 25000 }, before);
  await sleep(600);
  console.log(`  ${label}: window open`);
}

// Messages render COLLAPSED (the title row carries a truncated preview), so
// reading the body needs the rows expanded first — otherwise this suite would
// assert against an empty node list and pass by seeing nothing.
async function endLines() {
  await page.evaluate(() => {
    for (const el of document.querySelectorAll('.message.message-error')) {
      const header = el.querySelector('.msg-header');
      if (header && !el.querySelector('.message-content')) header.click();
    }
  });
  await sleep(400);
  return page.evaluate(() =>
    [...document.querySelectorAll('.message.message-error .message-content')].map((el) => el.textContent));
}

try {
  // ── A. died at startup, and said why on stderr ───────────────────
  console.log('== A. a core that dies before the protocol starts');
  writeFileSync(flag, '1');
  await createSession('A');
  await sleep(2500);
  let lines = await endLines();
  console.log('  transcript:', JSON.stringify(lines));
  assert(lines.some((t) => t.includes('session file version mismatch: got 11, expected 12')),
    'A: the core\'s stderr reason must reach the transcript — "Connection closed" alone is the bug this fixes');
  assert(lines.some((t) => t.startsWith('Connection closed:')),
    `A: the line must name the pipe fact the reason came attached to: ${JSON.stringify(lines)}`);
  rmSync(flag);

  // ── B. a live core, killed ───────────────────────────────────────
  console.log('== B. a healthy core killed under the session');
  await createSession('B');
  await page.waitForFunction(() => {
    const bars = [...document.querySelectorAll('.session-panel')];
    return bars.length && !bars[bars.length - 1].querySelector('.input-bubble.input-disabled');
  }, { timeout: 25000 });
  const beforeB = await endLines();
  const kids = execSync(`pgrep -P ${server.pid} || true`).toString().trim().split('\n').filter(Boolean);
  assert(kids.length > 0, 'B: the backend has no alayacore child to kill');
  execSync(`kill -9 ${kids.join(' ')}`);
  await sleep(2500);
  const afterB = await endLines();
  console.log('  transcript:', JSON.stringify(afterB));
  const addedB = afterB.filter((t) => !beforeB.includes(t)).length;
  assert(afterB.length > beforeB.length, 'B: the killed session must report an end');
  assert(afterB[afterB.length - 1] === 'Connection closed',
    `B: a SIGKILL writes nothing to stderr, so the line is the plain text: ${JSON.stringify(afterB)}`);

  // ── C. one death, one line ───────────────────────────────────────
  console.log('== C. the same death is not reported twice');
  await sleep(4000);
  const settled = await endLines();
  assert(settled.length === afterB.length,
    `C: exactly one end line per session, got ${afterB.length} → ${settled.length}: ${JSON.stringify(settled)}`);

  console.log('ALL PASS: why-a-session-ended');
} finally {
  await browser.close();
  server.kill('SIGKILL');
  rmSync(tmp, { recursive: true, force: true });
}

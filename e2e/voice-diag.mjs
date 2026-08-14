#!/usr/bin/env node
// Voice input diagnostic — headless Chrome + Go backend + fakecore.
// Opens the app, creates a Simple session, clicks the mic button twice
// (start/stop), and dumps everything: console messages, DOM state of
// the mic button, and whether asr_transcribe reached the backend.
import puppeteer from 'puppeteer-core';
import { execSync, spawn } from 'node:child_process';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import net from 'node:net';

const ROOT = path.resolve(import.meta.dirname, '..');
const CHROME = '/usr/bin/google-chrome';

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

const tmp = mkdtempSync(path.join(tmpdir(), 'alayaface-voice-diag-'));
const home = path.join(tmp, 'home');
const SRCGO = path.join(ROOT, 'src-go');
execSync(`mkdir -p "${home}"`);
const fakecore = path.join(tmp, 'fakecore');
const serverBin = path.join(tmp, 'alayaface-server');
execSync('go build -o "' + fakecore + '" ./internal/fakecore', { cwd: SRCGO, stdio: 'inherit' });
execSync('go build -o "' + serverBin + '" ./cmd/alayaface-server', { cwd: SRCGO, stdio: 'inherit' });

const port = await freePort();
const base = `http://127.0.0.1:${port}`;
const server = spawn(serverBin, ['--addr', `127.0.0.1:${port}`, '--static', '../src-elm', '--alayacore-bin', fakecore], {
  cwd: SRCGO,
  env: { ...process.env, HOME: home },
  stdio: ['ignore', 'pipe', 'pipe'],
});
server.stdout.on('data', d => process.stdout.write('[srv] ' + d));
server.stderr.on('data', d => process.stdout.write('[srv!] ' + d));

try {
  await waitPort(port, 30000);
  const browser = await puppeteer.launch({
    executablePath: CHROME,
    headless: true,
    args: [
      '--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu',
      '--window-size=1440,920',
      '--use-fake-ui-for-media-stream',          // auto-allow mic permission
      '--use-fake-device-for-media-stream',      // fake mic input
      '--autoplay-policy=no-user-gesture-required', // allow AudioContext to run
    ],
  });
  const page = await browser.newPage();
  await page.setViewport({ width: 1440, height: 920 });
  page.on('pageerror', e => console.log('[pageerror]', e.message));
  page.on('console', m => console.log('[console.' + m.type() + ']', m.text()));
  page.on('request', r => {
    if (r.url().includes('/rpc/')) console.log('[rpc request]', r.url().split('/rpc/')[1]);
  });
  page.on('response', async r => {
    if (r.status() >= 400) {
      const body = await r.text().catch(() => '');
      console.log('[http ' + r.status() + ']', r.url(), body.slice(0, 300));
    }
  });

  const waitFor = (sel, ms = 30000) => page.waitForSelector(sel, { timeout: ms, visible: true });
  const sleep = ms => new Promise(r => setTimeout(r, ms));

  await page.goto(base + '/', { waitUntil: 'networkidle0', timeout: 30000 });

  // Open global menu (right-click canvas) → New Session → Simple.
  await page.waitForSelector('.main-content', { timeout: 30000 });
  await page.$eval('.main-content', el => el.dispatchEvent(
    new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 30, clientY: 30 })));
  await waitFor('.global-menu-panel');
  const items = await page.$$('.global-menu-item');
  for (const h of items) {
    const t = await h.evaluate(el => el.textContent || '');
    if (t.includes('New Session')) {
      await h.click();
      await sleep(200);
      const subs = await page.$$('.global-menu-submenu-item');
      for (const s of subs) {
        if ((await s.evaluate(el => el.textContent || '')).includes('Simple')) { await s.click(); break; }
      }
      break;
    }
  }
  await waitFor('.session-panel');
  await sleep(800);

  // Hook the ports before clicking, to see if voiceStart is dispatched.
  await page.evaluate(() => {
    window.__diag = { voiceStart: 0, voiceStop: 0, voiceError: 0, asrResult: 0, cursorPos: 0 };
    const app = window.__diagApp;
    // Can't reach the Elm app object from outside; instead patch the
    // DOM click and observe state via MutationObserver on the button.
    window.__micObserved = [];
    const btn = document.querySelector('.mic-btn');
    if (!btn) { window.__micObserved.push('NO .mic-btn'); return; }
    new MutationObserver(muts => {
      for (const m of muts) {
        if (m.type === 'attributes' && (m.attributeName === 'class' || m.attributeName === 'title')) {
          window.__micObserved.push(m.attributeName + '=' + m.target.getAttribute(m.attributeName));
        }
      }
    }).observe(btn, { attributes: true });
    window.__micObserved.push('initial class=' + btn.className + ' disabled=' + btn.disabled);
  });
  await sleep(200);

  const micState = () => page.evaluate(() => {
    const btn = document.querySelector('.mic-btn');
    const ta = document.querySelector('textarea.input-text');
    const st = document.querySelector('.session-bar-status');
    return {
      micClass: btn ? btn.className : null,
      micDisabled: btn ? btn.disabled : null,
      micTitle: btn ? btn.title : null,
      inputValue: ta ? ta.value : null,
      status: st ? st.textContent : null,
    };
  });

  console.log('BEFORE click:', JSON.stringify(await micState()));

  // Click mic (start recording).
  await page.evaluate(() => {
    const btn = document.querySelector('.mic-btn');
    if (btn) { btn.click(); }
  });
  await sleep(1500);
  console.log('AFTER start:', JSON.stringify(await micState()));
  console.log('mutations:', JSON.stringify(await page.evaluate(() => window.__micObserved)));

  // Click again (stop + transcribe).
  await page.evaluate(() => {
    const btn = document.querySelector('.mic-btn');
    if (btn) { btn.click(); }
  });
  await sleep(4000);
  console.log('AFTER stop:', JSON.stringify(await micState()));

  await browser.close();
} finally {
  try { server.kill('SIGTERM'); } catch {}
  try { execSync(`rm -rf "${tmp}"`); } catch {}
}
console.log('DIAG DONE');

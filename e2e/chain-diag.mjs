#!/usr/bin/env node
// Chain-curve diagnostics (P39-A): headless Chrome + Go backend + fakecore.
// Dumps the connection-layer DOM state after a plan auto-creates, so we
// can see EXACTLY where each curve is drawn vs where the windows are.
// Run: node chain-diag.mjs   (keep artifacts: ALAYAFACE_KEEP_ARTIFACTS=1)
import puppeteer from 'puppeteer-core';
import { execSync, spawn } from 'node:child_process';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import net from 'node:net';

const ROOT = path.resolve(import.meta.dirname, '..');
const CHROME = '/usr/bin/google-chrome';
const tmp = mkdtempSync(path.join(tmpdir(), 'alayaface-diag-'));
const home = path.join(tmp, 'home');
const SRCGO = path.join(ROOT, 'src-go');
execSync(`mkdir -p "${home}"`);

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
server.stderr.on('data', d => process.stdout.write('[srv!] ' + d));
await waitPort(port, 15000);

const browser = await puppeteer.launch({
  executablePath: CHROME,
  headless: 'new',
  args: ['--no-sandbox', '--disable-gpu'],
});
const page = await browser.newPage();
page.on('console', m => { if (m.type() === 'error' || m.type() === 'warn') console.log('[page]', m.text().slice(0, 300)); });
page.on('pageerror', e => console.log('[pageerror]', String(e).slice(0, 300)));

await page.goto(base, { waitUntil: 'networkidle0' });

async function clickByText(sel, text) {
  return page.evaluate((sel, text) => {
    const el = [...document.querySelectorAll(sel)].find(b => (b.textContent || '').trim().includes(text));
    if (el) { el.click(); return true; }
    return false;
  }, sel, text);
}

// Open the settings gear → New Session
await page.waitForSelector('.global-menu-btn', { timeout: 15000 });
await page.click('.global-menu-btn');
await page.waitForSelector('.global-menu-panel', { timeout: 10000 });
await clickByText('.global-menu-item', 'New Session');
await page.waitForFunction(() => document.querySelectorAll('.session-panel').length > 0, { timeout: 15000 });
await sleep(600);
// Send the demo prompt (fakecore responds with a plan)
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
      ta.value = 'Create a demo plan for diag';
      ta.dispatchEvent(new Event('input', { bubbles: true }));
    }
    const btn = p.querySelector('.send-btn');
    if (btn) btn.click();
  }
});
await page.waitForFunction(() => document.querySelectorAll('.plan-panel').length > 0, { timeout: 30000 });
await sleep(1200);

// Run the plan → wait for completion (plan window auto-closes) → reopen
// via the status-bar button → click t1 node → its session resumes.
await page.evaluate(() => {
  const btn = [...document.querySelectorAll('button.plan-strip-btn')].find(b => (b.textContent || '').includes('Run'));
  if (btn) btn.click();
});
await page.waitForFunction(() => {
  return [...document.querySelectorAll('.plan-offer-btn')].some(e => e.textContent.includes('Completed'));
}, { timeout: 60000 }).catch(() => {});
await sleep(500);
await page.evaluate(() => {
  const btns = [...document.querySelectorAll('.plan-offer-btn')];
  const b = btns.find(x => x.textContent.includes('[Plan: e2e-demo-'));
  if (b) b.click();
});
await page.waitForFunction(() => document.querySelectorAll('.plan-panel').length > 0, { timeout: 15000 }).catch(() => {});
await sleep(500);
// Click the t1 node card.
await page.evaluate(() => {
  const panels = [...document.querySelectorAll('.plan-panel')];
  for (const p of panels) {
    const nodes = [...p.querySelectorAll('.plan-node')];
    for (const n of nodes) {
      const idEl = n.querySelector('.plan-node-id');
      if (idEl && idEl.textContent === 't1') { n.click(); return; }
    }
  }
});
await page.waitForFunction(() => {
  const t = document.querySelector('.session-panel.session-panel-active .session-bar-title')?.textContent || '';
  return t.includes('/t1');
}, { timeout: 30000 }).catch(() => {});
await sleep(800);

// ── Zoom verification (P39-A followup): after zooming, the curve
// endpoints (canvas coords) must still match the node card / window
// edges (canvas coords derived from rects divided by canvasScale).
async function dumpCurves(label) {
  return page.evaluate((label) => {
    const canvasEl = document.querySelector('.canvas');
    const m = canvasEl ? getComputedStyle(canvasEl).transform.match(/matrix\(([^)]+)\)/) : null;
    const scale = m ? parseFloat(m[1].split(',')[0]) : 1;
    const segs = [...document.querySelectorAll('.connection-seg')].map(s => {
      const p = s.querySelector('path');
      const d = p ? p.getAttribute('d') || '' : '';
      const nums = d.split(/[ MC,]/).filter(Boolean).map(Number);
      return {
        cls: p ? p.getAttribute('class') : null,
        display: getComputedStyle(s).display,
        left: parseFloat(s.style.left), top: parseFloat(s.style.top),
        // canvas coords of the path endpoints
        from: nums.length >= 4 ? { x: parseFloat(s.style.left) + nums[0], y: parseFloat(s.style.top) + nums[1] } : null,
        to: nums.length >= 4 ? { x: parseFloat(s.style.left) + nums[nums.length - 2], y: parseFloat(s.style.top) + nums[nums.length - 1] } : null,
      };
    });
    // Node card center in canvas coords (rect diff / scale, like chain.js).
    const planPanel = [...document.querySelectorAll('.plan-panel')].find(p => p.querySelector('.plan-node-id'));
    const node = planPanel && [...planPanel.querySelectorAll('.plan-node')]
      .find(n => (n.querySelector('.plan-node-id')?.textContent || '') === 't1');
    const nodeCanvas = null;
    return { label, scale, transform: m ? m[1] : null, segs, nodeCanvas };
  }, label);
}

// Zoom in (wheel over the empty canvas background — overlay.js forwards
// it to the onCanvasWheel port).
await page.evaluate(() => {
  const mc = document.querySelector('.main-content');
  if (mc) mc.dispatchEvent(new WheelEvent('wheel', { deltaY: -240, clientX: 10, clientY: 10, bubbles: true, cancelable: true }));
});
await sleep(600);
const zoomedIn = await page.evaluate(() => {
  const canvasEl = document.querySelector('.canvas');
  const m = getComputedStyle(canvasEl).transform.match(/matrix\(([^)]+)\)/);
  return m ? parseFloat(m[1].split(',')[0]) : 1;
});
// Zoom out below 1x too.
await page.evaluate(() => {
  const mc = document.querySelector('.main-content');
  if (mc) mc.dispatchEvent(new WheelEvent('wheel', { deltaY: 900, clientX: 10, clientY: 10, bubbles: true, cancelable: true }));
});
await sleep(600);
const zoomedOut = await page.evaluate(() => {
  const canvasEl = document.querySelector('.canvas');
  const m = getComputedStyle(canvasEl).transform.match(/matrix\(([^)]+)\)/);
  return m ? parseFloat(m[1].split(',')[0]) : 1;
});
console.log('zoom scales:', JSON.stringify({ zoomedIn, zoomedOut }));

// After both zooms, verify every visible curve endpoint against its
// participant's canvas position (derived from rects / scale).
const zoomCheck = await page.evaluate(() => {
  const canvasEl = document.querySelector('.canvas');
  const m = getComputedStyle(canvasEl).transform.match(/matrix\(([^)]+)\)/);
  const scale = m ? parseFloat(m[1].split(',')[0]) : 1;
  const planPanel = [...document.querySelectorAll('.plan-panel')].find(p => p.querySelector('.plan-node-id'));
  const node = planPanel && [...planPanel.querySelectorAll('.plan-node')]
    .find(n => (n.querySelector('.plan-node-id')?.textContent || '') === 't1');
  const nodeCanvas = node && planPanel ? (() => {
    const er = node.getBoundingClientRect();
    const wr = planPanel.getBoundingClientRect();
    return {
      x: parseFloat(planPanel.style.left) + (er.left - wr.left) / scale + node.offsetWidth / 2,
      y: parseFloat(planPanel.style.top) + (er.top - wr.top) / scale + node.offsetHeight / 2,
    };
  })() : null;
  const results = [];
  for (const s of document.querySelectorAll('.connection-seg')) {
    if (getComputedStyle(s).display === 'none') continue;
    const p = s.querySelector('path');
    const d = p ? p.getAttribute('d') || '' : '';
    const nums = d.split(/[ MC,]/).filter(Boolean).map(Number);
    if (nums.length < 4) continue;
    const cls = p.getAttribute('class') || '';
    const from = { x: parseFloat(s.style.left) + nums[0], y: parseFloat(s.style.top) + nums[1] };
    const to = { x: parseFloat(s.style.left) + nums[nums.length - 2], y: parseFloat(s.style.top) + nums[nums.length - 1] };
    if (cls.includes('node')) {
      results.push({
        seg: 'node',
        to,
        nodeCanvas,
        dx: nodeCanvas ? Math.abs(to.x - nodeCanvas.x) : null,
        dy: nodeCanvas ? Math.abs(to.y - nodeCanvas.y) : null,
        ok: nodeCanvas ? (Math.abs(to.x - nodeCanvas.x) < 4 && Math.abs(to.y - nodeCanvas.y) < 4) : false,
      });
    } else {
      // plan segment: from must lie on the plan window edge; to must lie
      // on the session edge (or its [Plan:] button).
      results.push({ seg: 'plan', from, to, ok: true });
    }
  }
  return { scale, results, nodeCanvas };
});
console.log('zoomCheck:', JSON.stringify(zoomCheck, null, 1));
const nodeSeg = (zoomCheck.results || []).find(r => r.seg === 'node');
if (!nodeSeg || !nodeSeg.ok) {
  console.error('ZOOM FAIL: node curve endpoint drifted from the node card after zoom');
  process.exitCode = 2;
} else {
  console.log('ZOOM OK: node curve endpoint matches the node card center at scale ' + zoomCheck.scale.toFixed(2));
}

const dump = await page.evaluate(() => {
  const segs = [...document.querySelectorAll('.connection-seg')].map(s => {
    const p = s.querySelector('path');
    return {
      cls: p ? p.getAttribute('class') : null,
      left: s.style.left, top: s.style.top,
      w: s.getAttribute('width'), h: s.getAttribute('height'),
      z: s.style.zIndex, display: getComputedStyle(s).display,
      d: p ? p.getAttribute('d') : null,
      strokeWidth: p ? p.getAttribute('stroke-width') : null,
    };
  });
  const canvas = document.querySelector('.canvas');
  const ctr = canvas ? canvas.getBoundingClientRect() : null;
  const transform = canvas ? getComputedStyle(canvas).transform : null;
  const panels = [...document.querySelectorAll('.session-panel,.plan-panel')].map(p => {
    const r = p.getBoundingClientRect();
    return {
      kind: p.classList.contains('plan-panel') ? 'plan' : 'session',
      id: p.dataset.session || p.dataset.plan,
      rect: { left: r.left, top: r.top, w: r.width, h: r.height },
      styleLeft: p.style.left, styleTop: p.style.top, z: p.style.zIndex,
    };
  });
  const nodes = [...document.querySelectorAll('.plan-panel .plan-node')].map(n => {
    const r = n.getBoundingClientRect();
    return {
      id: n.querySelector('.plan-node-id')?.textContent || '',
      rect: { left: r.left, top: r.top, w: r.width, h: r.height },
    };
  });
  const btn = [...document.querySelectorAll('button')]
    .find(b => /^\[Plan: /.test((b.textContent || '').trim()));
  const br = btn ? btn.getBoundingClientRect() : null;
  const activeTitle = document.querySelector('.session-panel.session-panel-active .session-bar-title')?.textContent || '';
  return {
    segs, ctr: ctr ? { left: ctr.left, top: ctr.top, w: ctr.width, h: ctr.height } : null,
    transform, panels, nodes,
    activeTitle,
    lastChain: window.__lastChainPayload ? window.__lastChainPayload.segments : null,
    lastChainPositions: window.__lastChainPayload ? window.__lastChainPayload.positions : null,
    geomFail: window.__chainGeomFail || null,
    drawLog: window.__chainDrawLog || null,
    btn: br ? { left: br.left, top: br.top, w: br.width, h: br.height, text: (btn.textContent || '').slice(0, 30) } : null,
  };
});
console.log(JSON.stringify(dump, null, 1));

// Compute screen coords of each curve endpoint (canvas coord → screen)
if (dump.transform) {
  const m = /matrix\(([^)]+)\)/.exec(dump.transform);
  const parts = m ? m[1].split(',').map(Number) : null;
  console.log('\n--- curve endpoint screen positions (canvas→screen) ---');
  for (const s of dump.segs) {
    if (!s.d || s.display === 'none') continue;
    const nums = s.d.split(/[ MC,]/).filter(Boolean).map(Number);
    const sx = (Number(s.left) + nums[nums.length - 2]) * (parts ? parts[0] : 1) + (parts ? parts[4] : 0) + (dump.ctr ? dump.ctr.left : 0);
    const sy = (Number(s.top) + nums[nums.length - 1]) * (parts ? parts[3] : 1) + (parts ? parts[5] : 0) + (dump.ctr ? dump.ctr.top : 0);
    const fx = (Number(s.left) + nums[0]) * (parts ? parts[0] : 1) + (parts ? parts[4] : 0) + (dump.ctr ? dump.ctr.left : 0);
    const fy = (Number(s.top) + nums[1]) * (parts ? parts[3] : 1) + (parts ? parts[5] : 0) + (dump.ctr ? dump.ctr.top : 0);
    console.log(s.cls, 'from=(' + fx.toFixed(0) + ',' + fy.toFixed(0) + ') to=(' + sx.toFixed(0) + ',' + sy.toFixed(0) + ')');
  }
  console.log('\npanels:');
  for (const p of dump.panels) {
    console.log(' ', p.kind, p.id, 'screen=(' + p.rect.left.toFixed(0) + ',' + p.rect.top.toFixed(0) + ') size=' + p.rect.w + 'x' + p.rect.h, 'canvasStyle=(' + p.styleLeft + ',' + p.styleTop + ') z=' + p.z);
  }
  if (dump.btn) console.log('  [Plan:] btn screen=(' + dump.btn.left.toFixed(0) + ',' + dump.btn.top.toFixed(0) + ') ' + dump.btn.w + 'x' + dump.btn.h);
}

await browser.close();
server.kill('SIGTERM');
const KEEP = process.env.ALAYAFACE_KEEP_ARTIFACTS === '1';
if (!KEEP) { try { rmSync(tmp, { recursive: true, force: true }); } catch {} }

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

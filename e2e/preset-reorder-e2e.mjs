// Preset Manager drag-to-reorder E2E: opens the app in headless Chrome,
// creates an extra preset, opens Preset Manager, simulates an HTML5
// drag (dragstart on the ⠿ handle → dragover → drop on another row),
// and asserts the reorder is applied in the UI, persisted to
// ~/.alayaface/preset_order.conf, returned by list_presets, survives a
// manager reopen, and drives the New Session submenu order.
import puppeteer from "puppeteer-core";
import { spawn } from "child_process";
import { mkdtempSync, rmSync, existsSync, readFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";

const CHROME = process.env.CHROME || "/usr/bin/google-chrome";
const GO_DIR = join(process.cwd(), "..", "src-go");
const FAKECORE = join(GO_DIR, "bin", "fakecore");
const SERVER = join(GO_DIR, "bin", "alayaface-server");
const STATIC = join(process.cwd(), "..", "src-elm");

const home = mkdtempSync(join(tmpdir(), "alayaface-dr-"));
const port = 9101 + Math.floor(Math.random() * 200);
const env = { ...process.env, HOME: home };
console.log("HOME:", home, "port:", port);

const server = spawn(SERVER, ["--addr", `127.0.0.1:${port}`, "--static", STATIC, "--alayacore-bin", FAKECORE], { env, stdio: "inherit" });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const waitFor = async (fn, timeout = 15000) => {
  const start = Date.now();
  for (;;) {
    try {
      const v = await fn();
      if (v) return v;
    } catch (e) { /* retry */ }
    if (Date.now() - start > timeout) throw new Error("timeout waiting for condition");
    await sleep(120);
  }
};

const rpc = (path, body) =>
  fetch(`http://127.0.0.1:${port}/rpc/${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  }).then((r) => r.text().then((t) => (t ? JSON.parse(t) : null)));

function assert(cond, msg) {
  if (!cond) throw new Error("ASSERT FAILED: " + msg);
  console.log("  ✓", msg);
}

async function main() {
  await waitFor(async () => { try { await rpc("list_presets", {}); return true; } catch { return false; } });

  // Seed list: Simple, Complex. Add one more so reorder is meaningful.
  await rpc("copy_preset", { source: "Simple", name: "work" });
  // The copy is async on the backend: wait for the seeded list (sorted
  // alphabetically) instead of asserting immediately after the RPC.
  const presets = await waitFor(async () => {
    const ps = await rpc("list_presets", {});
    return ps && ps.map((p) => p.name).join(",") === "Complex,Simple,Talk,work" ? ps : null;
  }, 10000);
  console.log("initial presets:", presets.map((p) => p.name).join(", "));
  assert(presets.map((p) => p.name).join(",") === "Complex,Simple,Talk,work", "default alphabetical order");
  let presetsReordered = presets;

  const browser = await puppeteer.launch({ executablePath: CHROME, headless: true, args: ["--no-sandbox", "--disable-gpu"] });
  const page = await browser.newPage();
  await page.setViewport({ width: 1280, height: 860 });
  page.on("pageerror", (e) => console.log("[pageerror]", String(e).slice(0, 300)));
  page.on("console", (m) => { if (m.type() === "error" || m.type() === "warn") console.log("[console." + m.type() + "]", m.text().slice(0, 300)); });
  await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: "networkidle0", timeout: 20000 });

  // Open Preset Manager (right-click canvas → menu item). Dispatch the
  // contextmenu event on .main-content (a real mouse right-click can be
  // swallowed by the pointer layer).
  await page.waitForSelector(".main-content", { timeout: 15000 });
  await page.$eval(".main-content", (el) => el.dispatchEvent(
    new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 30, clientY: 30 })));
  await waitFor(() => page.evaluate(() => [...document.querySelectorAll(".global-menu-item")].some((el) => el.textContent.includes("Preset Manager"))));
  await page.evaluate(() => [...document.querySelectorAll(".global-menu-item")].find((el) => el.textContent.includes("Preset Manager")).click());
  await waitFor(() => page.evaluate(() => !!document.querySelector(".pm-row")));

  const names = () => page.evaluate(() =>
    [...document.querySelectorAll(".pm-row .pm-name")].map((el) => el.textContent));
  assert((await names()).join(",") === "Complex,Simple,Talk,work", "manager rows render in order");

  const handles = await page.evaluate(() => [...document.querySelectorAll(".pm-drag-handle")].length);
  assert(handles === 4, "each row has a drag handle");

  // Synthetic HTML5 drag: drag row 0 (Complex) onto the last row (work).
  const result = await page.evaluate(() => {
    const rows = [...document.querySelectorAll(".pm-row")];
    const src = rows[0].querySelector(".pm-drag-handle");
    const dst = rows[rows.length - 1];
    const dt = new DataTransfer();
    const fire = (target, type) => {
      const ev = new DragEvent(type, { bubbles: true, cancelable: true, dataTransfer: dt });
      target.dispatchEvent(ev);
      return !ev.defaultPrevented;
    };
    const started = fire(src, "dragstart");
    const overEv = (() => { const ev = new DragEvent("dragover", { bubbles: true, cancelable: true, dataTransfer: dt }); dst.dispatchEvent(ev); return ev; })();
    const over = overEv.defaultPrevented; // preventDefaultOn → true = drop allowed
    const dropped = fire(dst, "drop");
    fire(src, "dragend");
    return { started, over, dropped };
  });
  console.log("drag events:", JSON.stringify(result));
  assert(result.started && result.over && result.dropped, "dragstart/dragover(preventDefault)/drop dispatched");

  // UI reordered immediately.
  await waitFor(async () => (await names()).join(",") === "Simple,Talk,work,Complex", 5000);
  console.log("  ✓ UI list reordered to Simple,Talk,work,Complex");

  // Persisted to disk (preset_order.conf).
  await waitFor(() => {
    const f = join(home, ".alayaface", "preset_order.conf");
    if (!existsSync(f)) return false;
    const arr = JSON.parse(readFileSync(f, "utf8"));
    return arr.join(",") === "Simple,Talk,work,Complex";
  }, 5000);
  console.log("  ✓ preset_order.conf persisted");

  // Backend list_presets returns the new order.
  presetsReordered = await rpc("list_presets", {});
  assert(presetsReordered.map((p) => p.name).join(",") === "Simple,Talk,work,Complex", "list_presets returns new order");

  // Reopen the manager → order survives.
  await page.evaluate(() => document.querySelector(".card-close").click());
  await waitFor(() => page.evaluate(() => !document.body.textContent.includes("Preset Manager")));
  await page.$eval(".main-content", (el) => el.dispatchEvent(
    new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 30, clientY: 30 })));
  await waitFor(() => page.evaluate(() => [...document.querySelectorAll(".global-menu-item")].some((el) => el.textContent.includes("Preset Manager"))));
  await page.evaluate(() => [...document.querySelectorAll(".global-menu-item")].find((el) => el.textContent.includes("Preset Manager")).click());
  await waitFor(() => page.evaluate(() => !!document.querySelector(".pm-row")));
  assert((await names()).join(",") === "Simple,Talk,work,Complex", "order survives reopen");

  // Global New Session submenu also uses the same order.
  await page.evaluate(() => document.querySelector(".card-close").click());
  await waitFor(() => page.evaluate(() => !document.body.textContent.includes("Preset Manager")));
  await page.$eval(".main-content", (el) => el.dispatchEvent(
    new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 30, clientY: 30 })));
  await waitFor(() => page.evaluate(() => [...document.querySelectorAll(".global-menu-item")].some((el) => el.textContent.includes("New Session"))));
  await page.evaluate(() => [...document.querySelectorAll(".global-menu-item")].find((el) => el.textContent.includes("New Session")).click());
  const submenu = await page.evaluate(() => [...document.querySelectorAll(".global-menu-submenu-item")].map((el) => el.textContent));
  assert(submenu.join(",") === "Simple,Talk,work,Complex", "New Session submenu uses reordered list: " + submenu.join(","));

  await browser.close();
  console.log("ALL PASS");
}

main()
  .catch((e) => { console.error(e); process.exitCode = 1; })
  .finally(() => {
    server.kill("SIGTERM");
    setTimeout(() => { try { rmSync(home, { recursive: true, force: true }); } catch {} }, 500);
  });

// Reasoning-level settings E2E probe: opens the app in headless Chrome,
// goes to Preset Manager → Edit → Settings, verifies the Reasoning level
// select (Off/Balanced/Deep), sets it to Deep (2), saves, creates a
// session, and asserts the session's reasoning select shows "Deep" (the
// fakecore boot frame carries --reasoning-level=2 → SM reasoning).
import puppeteer from "puppeteer-core";
import { spawn } from "child_process";
import { mkdtempSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";

const CHROME = process.env.CHROME || "/usr/bin/google-chrome";
const GO_DIR = join(process.cwd(), "..", "src-go");
const FAKECORE = join(GO_DIR, "bin", "fakecore");
const SERVER = join(GO_DIR, "bin", "alayaface-server");
const STATIC = join(process.cwd(), "..", "src-elm");

const home = mkdtempSync(join(tmpdir(), "alayaface-rl-"));
const port = 8931 + Math.floor(Math.random() * 200);
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
  }).then((r) => r.json());

async function main() {
  await waitFor(async () => { try { await rpc("list_presets", {}); return true; } catch { return false; } });

  const browser = await puppeteer.launch({ executablePath: CHROME, headless: true, args: ["--no-sandbox", "--disable-gpu"] });
  const page = await browser.newPage();
  await page.setViewport({ width: 1280, height: 860 });
  page.on("console", (m) => { if (m.type() === "error") console.log("[console.error]", m.text().slice(0, 200)); });
  page.on("pageerror", (e) => console.log("[pageerror]", String(e).slice(0, 200)));

  await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: "networkidle0", timeout: 20000 });

  // Open the global menu: right-click the canvas (contextmenu).
  await page.mouse.click(400, 300, { button: "right" });
  await waitFor(() => page.evaluate(() => [...document.querySelectorAll(".global-menu-item")].some((el) => el.textContent.includes("Preset Manager"))));
  await page.evaluate(() => [...document.querySelectorAll(".global-menu-item")].find((el) => el.textContent.includes("Preset Manager")).click());
  await waitFor(() => page.evaluate(() => document.body.textContent.includes("Preset Manager") && !!document.querySelector(".pm-row")));

  // Find the row for "Simple", click Edit → Settings.
  await page.evaluate(() => {
    const rows = [...document.querySelectorAll(".pm-row")];
    const row = rows.find((r) => r.querySelector(".pm-name") && r.querySelector(".pm-name").textContent === "Simple");
    [...row.querySelectorAll("button")].find((b) => b.textContent === "Edit").click();
  });
  await waitFor(() => page.evaluate(() => document.body.textContent.includes("Edit Simple:")));
  await page.evaluate(() => {
    const rows = [...document.querySelectorAll(".pm-edit-row")];
    rows.forEach((r) => {
      const btn = [...r.querySelectorAll("button")].find((b) => b.textContent.trim() === "Settings");
      if (btn) btn.click();
    });
  });

  // Settings page: wait for the reasoning select and check options.
  await waitFor(() => page.$("#settings-reasoning-level"));
  const opts = await page.evaluate(() => [...document.querySelectorAll("#settings-reasoning-level option")].map((o) => o.textContent));
  const val = await page.evaluate(() => document.querySelector("#settings-reasoning-level").value);
  console.log("reasoning select options:", JSON.stringify(opts), "value:", val);
  if (opts.join(",") !== "Off,Balanced,Deep") throw new Error("bad options: " + opts);
  if (val !== "1") throw new Error("default should be 1 (Balanced), got " + val);

  // The page must not clip: me-fields overflows and scrolls inside the
  // fixed-height overlay, and the Save/Cancel row stays visible.
  const layout = await page.evaluate(() => {
    const f = document.querySelector(".me-fields");
    const a = document.querySelector(".me-actions");
    const pageEl = document.querySelector(".overlay-page");
    if (!f || !a || !pageEl) return null;
    const fRect = f.getBoundingClientRect();
    const aRect = a.getBoundingClientRect();
    const pRect = pageEl.getBoundingClientRect();
    return {
      fieldsOverflow: f.scrollHeight > f.clientHeight,
      fieldsScrollable: getComputedStyle(f).overflowY === "auto",
      actionsInsidePage: aRect.bottom <= pRect.bottom + 1 && aRect.top >= pRect.top - 1,
    };
  });
  console.log("settings layout:", JSON.stringify(layout));
  if (!layout || !layout.fieldsOverflow || !layout.fieldsScrollable || !layout.actionsInsidePage) {
    throw new Error("settings page clipped: " + JSON.stringify(layout));
  }

  // Set Deep (2) and save.
  await page.select("#settings-reasoning-level", "2");
  await waitFor(() => page.evaluate(() => document.querySelector("#settings-reasoning-level").value === "2"));
  await page.evaluate(() => {
    const btn = [...document.querySelectorAll("button")].find((b) => b.textContent.trim() === "Save");
    btn.click();
  });
  // Saving closes the editor → back to Preset Manager.
  await waitFor(() => page.evaluate(() => !document.querySelector("#settings-reasoning-level")));
  console.log("settings saved (Deep)");

  // Verify on the backend: get_global_settings returns 2.
  const gs = await rpc("get_global_settings", { preset: "Simple" });
  console.log("get_global_settings:", JSON.stringify(gs));
  if (gs.reasoning_level !== 2) throw new Error("preset reasoning_level should be 2, got " + gs.reasoning_level);

  // Close the preset manager (× overlay-close), then New Session.
  await page.evaluate(() => { const b = document.querySelector(".overlay-close"); if (b) b.click(); });
  console.log("clicked overlay-close; body has PresetManager:",
    await page.evaluate(() => document.body.textContent.includes("Preset Manager")));
  await waitFor(() => page.evaluate(() => !document.body.textContent.includes("Preset Manager")));
  console.log("preset manager closed");
  await page.evaluate(() => {
    const item = [...document.querySelectorAll(".global-menu-item")].find((el) => el.textContent.includes("New Session"));
    if (item) item.click();
  });
  // New Session submenu is click-only: reopen the global menu, click the
  // item, then the preset.
  await page.mouse.click(400, 300, { button: "right" });
  await waitFor(() => page.evaluate(() => [...document.querySelectorAll(".global-menu-item")].some((el) => el.textContent.includes("New Session"))));
  await page.evaluate(() => {
    const item = [...document.querySelectorAll(".global-menu-item")].find((el) => el.textContent.includes("New Session"));
    if (item) item.click();
  });
  await waitFor(() => page.evaluate(() => [...document.querySelectorAll(".global-menu-submenu-item")].some((el) => el.textContent.includes("Simple"))));
  console.log("new session submenu open");
  await page.evaluate(() => {
    const el = [...document.querySelectorAll(".global-menu-submenu-item")].find((x) => x.textContent.includes("Simple"));
    el.click();
  });
  console.log("clicked Simple preset");
  await waitFor(() => page.evaluate(() => !!document.querySelector(".session-window") || !!document.querySelector(".session-panel") || !!document.querySelector(".reasoning-select")), 20000);
  console.log("session window present; body snippet:",
    (await page.evaluate(() => document.body.textContent.replace(/\s+/g, " ").slice(0, 300))));
  // Dump the current select value after a beat, then keep polling.
  await sleep(1500);
  console.log("select value now:",
    await page.evaluate(() => document.querySelector(".reasoning-select") ? document.querySelector(".reasoning-select").value : "no-select"));

  // Wait for the session window + reasoning select to show "Deep".
  await waitFor(() => page.evaluate(() => !!document.querySelector(".reasoning-select")), 20000);
  const finalVal = await waitFor(async () => {
    const v = await page.evaluate(() => document.querySelector(".reasoning-select") && document.querySelector(".reasoning-select").value);
    return v === "2" ? v : null;
  }, 20000);
  console.log("session reasoning select after boot:", finalVal);

  // And assert the persisted spawn args carry reasoning_level=2.
  const { readdirSync } = await import("fs");
  const sessionsRoot = `${home}/.alayaface/sessions`;
  const sid = readdirSync(sessionsRoot)[0];
  const spawnPath = `${sessionsRoot}/${sid}/session.spawn.json`;
  const spawnRes = await waitFor(async () => {
    const { readFileSync } = await import("fs");
    try { return JSON.parse(readFileSync(spawnPath, "utf8")); } catch { return null; }
  });
  console.log("spawn.json:", JSON.stringify(spawnRes));
  if (spawnRes.reasoning_level !== 2) throw new Error("spawn.json reasoning_level should be 2, got " + spawnRes.reasoning_level);

  await browser.close();
  console.log("ALL PASS");
}

main().catch((e) => { console.error("FAIL:", e.message); process.exitCode = 1; })
  .finally(() => { server.kill("SIGKILL"); setTimeout(() => rmSync(home, { recursive: true, force: true }), 500); });

// MCP-config E2E probe: proves the MCP editor writes a complete, core-readable
// mcp.conf through the ONE codec in App/McpConfig.elm.
//
// Why this suite exists: the codec used to live in both backends, with no
// parity check, and they had drifted. Go quoted values with `json.Marshal`,
// which escapes `&`, `<` and `>` as `\u0026`/`\u003c`/`\u003e` — strings
// AlayaCore's parser does not unescape — so a URL with a query string was
// corrupted by one backend and not the other. The same path silently dropped
// `auth-scopes`, a key the core reads, because neither backend modelled it.
//
// What is asserted:
//   1. a key this build does not model (`custom-key`) survives an edit+save;
//   2. `auth-scopes` is editable and reaches the file;
//   3. `&`, `<`, `>` in a value are written literally (not JSON-escaped);
//   4. the file is 0600 (OAuth secrets);
//   5. broken JSON in a JSON field disables Save and names the field.
import puppeteer from "puppeteer-core";
import { spawn } from "child_process";
import { mkdtempSync, rmSync, readFileSync, writeFileSync, statSync, mkdirSync } from "fs";
import { tmpdir } from "os";
import { join, resolve } from "path";
import { buildGoBinaries } from "./build-binaries.mjs";

const CHROME = process.env.CHROME || "/usr/bin/google-chrome";
const ROOT = resolve(import.meta.dirname, "..");
let FAKECORE, SERVER;
const STATIC = join(ROOT, "src-elm");

const home = mkdtempSync(join(tmpdir(), "alayaface-mcp-"));
const port = 9431 + Math.floor(Math.random() * 200);
const env = { ...process.env, HOME: home };
console.log("HOME:", home, "port:", port);

({ fakecore: FAKECORE, server: SERVER } = buildGoBinaries(ROOT));

const server = spawn(SERVER, ["--addr", `127.0.0.1:${port}`, "--static", STATIC, "--alayacore-bin", FAKECORE], { env, stdio: "inherit" });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const waitFor = async (fn, timeout = 15000, what = "") => {
  const start = Date.now();
  let last = null;
  for (;;) {
    try {
      const v = await fn();
      if (v) return v;
    } catch (e) {
      last = e;
    }
    if (Date.now() - start > timeout) {
      throw new Error("timeout waiting for " + (what || "condition") + (last ? " (last error: " + String(last.message).slice(0, 200) + ")" : ""));
    }
    await sleep(120);
  }
};

const PRESET_DIR = join(home, ".alayaface", "presets", "Simple");
const MCP_FILE = join(PRESET_DIR, "mcp.conf");
const fieldId = (key) => `#mcp-editor-${key}-default`;

// A key this build does not model, seeded before the UI opens, so the only
// way it can be present after a save is the codec's `extras`.
const SEED = `server: "seeded"
url: "https://seeded.example/mcp"
custom-key: "kept"
`;

let page;

// The Preset Manager stays open underneath the MCP editor, so reopening the
// editor must NOT try the global menu again (the overlay swallows the
// right-click).
async function ensurePresetManagerOpen() {
  const open = await page.evaluate(() => !!document.querySelector(".pm-row"));
  if (open) return;

  await page.waitForSelector(".main-content", { timeout: 15000 });
  await page.$eval(".main-content", (el) => el.dispatchEvent(
    new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 30, clientY: 30 })));
  const menuClick = (label) => page.evaluate((text) => {
    const item = [...document.querySelectorAll(".global-menu-item")].find((el) => el.textContent.includes(text));
    if (!item) throw new Error("no menu item " + text);
    item.click();
  }, label);
  await waitFor(() => page.evaluate(() => [...document.querySelectorAll(".global-menu-item")].some((el) => el.textContent.includes("Preset Manager"))));
  await menuClick("Preset Manager");
  await waitFor(() => page.evaluate(() => !!document.querySelector(".pm-row")), 15000, "Preset Manager rows");
}

async function openMcpEditor() {
  await ensurePresetManagerOpen();
  await page.evaluate(() => {
    const row = [...document.querySelectorAll(".pm-row")].find((r) => r.querySelector(".pm-name")?.textContent === "Simple");
    const edit = [...row.querySelectorAll("button")].find((b) => b.textContent === "Edit");
    if (edit) edit.click();
  });
  await waitFor(() => page.evaluate(() => document.body.textContent.includes("Edit Simple:")), 15000, "Edit Simple panel");
  await page.evaluate(() => {
    const rows = [...document.querySelectorAll(".pm-edit-row")];
    const btn = rows.flatMap((r) => [...r.querySelectorAll("button")]).find((b) => b.textContent.trim() === "MCP Servers");
    btn.click();
  });
  await waitFor(() => page.evaluate(() => !!document.querySelector("#mcp-selector-input-default")), 15000, "MCP list");
}

async function editServer(id) {
  await page.evaluate((rowId) => {
    const row = document.querySelector(`#mcp-selector-item-default-${rowId}`);
    if (!row) throw new Error("no server row " + rowId);
    [...row.querySelectorAll("button")].find((b) => b.textContent.trim() === "Edit").click();
  }, id);
  await waitFor(() => page.evaluate(() => !!document.querySelector("#mcp-editor-server-default")), 15000, "MCP editor form");
}

const saveDisabled = () =>
  page.evaluate(() => {
    const b = [...document.querySelectorAll(".me-actions button")].find((x) => x.textContent.trim() === "Save");
    return b ? b.disabled : null;
  });

const errorLines = () =>
  page.evaluate(() => [...document.querySelectorAll(".me-field-error")].map((el) => el.textContent));

async function setField(key, value) {
  const sel = fieldId(key);
  const tag = await page.evaluate((s) => document.querySelector(s)?.tagName, sel);
  if (tag === "SELECT") {
    await page.select(sel, value);
  } else {
    await page.evaluate((s, v) => {
      const el = document.querySelector(s);
      const proto = el.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(proto, "value").set.call(el, v);
      el.dispatchEvent(new Event("input", { bubbles: true }));
    }, sel, value);
  }
  await waitFor(() => page.evaluate((s, v) => document.querySelector(s).value === v, sel, value), 10000, "field " + key);
}

async function clickButton(text) {
  await page.evaluate((label) => {
    const b = [...document.querySelectorAll("button")].find((x) => x.textContent.trim() === label);
    if (!b) throw new Error("no button " + label);
    b.click();
  }, text);
}

async function main() {
  await waitFor(async () => { try { await fetch(`http://127.0.0.1:${port}/rpc/list_presets`, { method: "POST" }); return true; } catch { return false; } });
  // Seed the preset (and the unmodelled key) before the UI reads it.
  await fetch(`http://127.0.0.1:${port}/rpc/list_default_mcp`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ preset: "Simple" }),
  });
  mkdirSync(PRESET_DIR, { recursive: true });
  writeFileSync(MCP_FILE, SEED);

  const browser = await puppeteer.launch({ executablePath: CHROME, headless: true, args: ["--no-sandbox", "--disable-gpu"] });
  page = await browser.newPage();
  await page.setViewport({ width: 1280, height: 900 });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  // A missing favicon is a 404 the server logs; it is not a page error.
  page.on("console", (m) => {
    if (m.type() === "error" && !/Failed to load resource/.test(m.text())) errors.push(m.text());
  });
  await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: "networkidle0", timeout: 20000 });

  await openMcpEditor();

  // ── 1. edit the seeded server, fill every field worth pinning ──
  await editServer(1);
  await setField("server", "e2e-mcp");
  await setField("url", "https://mcp.example.com/mcp?a=1&b=2<c>");
  await setField("auth-type", "authorization_code");
  await waitFor(() => page.evaluate(() => !!document.querySelector("#mcp-editor-auth-scopes-default")), 10000, "auth-scopes field");
  await setField("auth-client-id", "cid");
  await setField("auth-client-secret", "secret");
  await setField("auth-scopes", '["read", "write"]');
  await clickButton("Save");
  await waitFor(() => page.evaluate(() => !document.querySelector("#mcp-editor-server-default")), 10000, "editor to return to the list");

  // ── 2. sync, then read the file the backend actually wrote ──
  await page.evaluate(() => {
    const closes = [...document.querySelectorAll(".card-close")];
    closes[closes.length - 1].click();
  });
  await waitFor(() => page.evaluate(() => document.body.textContent.includes("Sync & Close")), 15000, "sync prompt");
  await clickButton("Sync & Close");
  const text = await waitFor(() => {
    try {
      const t = readFileSync(MCP_FILE, "utf8");
      return t.includes("e2e-mcp") ? t : null;
    } catch { return null; }
  }, 15000, "the backend to write mcp.conf");
  console.log("written mcp.conf:\n" + text);

  const check = (cond, msg) => { if (!cond) throw new Error(msg); };
  check(text.includes('server: "e2e-mcp"'), "edited server name missing");
  check(text.includes('url: "https://mcp.example.com/mcp?a=1&b=2<c>"'),
    "a URL containing & < > was altered (JSON escaping instead of the core's)");
  check(text.includes('auth-scopes: ["read","write"]'), "auth-scopes missing from the written file");
  check(text.includes('custom-key: "kept"'), "the un-modelled key custom-key was deleted by the edit");
  check(text.includes('auth-client-id: "cid"') && text.includes('auth-client-secret: "secret"'), "auth credentials lost");
  check((statSync(MCP_FILE).mode & 0o777) === 0o600, "mcp.conf is not 0600");

  // ── 3. reopen: the fields round-trip, and validation blocks Save ──
  await openMcpEditor();
  await editServer(1);
  check((await page.evaluate((s) => document.querySelector(s).value, fieldId("auth-scopes"))) === '["read","write"]',
    "auth-scopes did not round-trip through the editor");

  await setField("auth-client-id", "");
  check((await saveDisabled()) === true, "Save stayed enabled with a required auth field empty");
  const lines = await errorLines();
  check(lines.some((l) => l.includes("Auth Client ID")), "missing field error for auth-client-id: " + JSON.stringify(lines));
  await setField("auth-client-id", "cid");

  await setField("auth-scopes", "not json");
  check((await saveDisabled()) === true, "Save stayed enabled with unparsable auth-scopes JSON");
  check((await errorLines()).some((l) => l.toLowerCase().includes("auth-scopes")), "no error naming auth-scopes");
  await setField("auth-scopes", '["read"]');
  check((await saveDisabled()) === false, "Save stayed disabled after the field was fixed");

  check(errors.length === 0, "console/page errors: " + JSON.stringify(errors));
  console.log("ALL PASS");

  await browser.close();
}

main().catch((e) => { console.error("FAIL:", e.message); process.exitCode = 1; })
  .finally(() => { server.kill("SIGKILL"); setTimeout(() => rmSync(home, { recursive: true, force: true }), 500); });

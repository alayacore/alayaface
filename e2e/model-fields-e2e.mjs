// Model-config E2E probe: proves AlayaFace carries EVERY model.conf field
// through an edit+sync.
//
// Why this exists as its own suite: :model_sync replaces the whole list and
// AlayaCore rewrites model.conf from what comes back, so a field the client
// does not carry is a field deleted from the user's config file. Losing
// `reasoning_field` reads as "the REASONING window never appears" and losing
// `serial_tool_calls: true` as "tool calls overlapped again" — with no error
// anywhere. Three things are asserted here, in order:
//
//   1. the editor presents a control for every field, prefilled from what
//      fakecore's model_list sent (incl. an unset block and an absent key);
//   2. a value the codec cannot encode (unparsable provider JSON) blocks
//      Save instead of being dropped on save;
//   3. after Sync, the payload AlayaCore received still carries every field
//      of BOTH entries — the one that was edited and the one that was not —
//      including `quantization`, a key AlayaFace has never heard of.
//
// fakecore records each model_sync payload in <preset>/model_sync.last.json,
// which is what step 3 reads.
import puppeteer from "puppeteer-core";
import { spawn } from "child_process";
import { mkdtempSync, rmSync, readFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { buildGoBinaries } from "./build-binaries.mjs";

const CHROME = process.env.CHROME || "/usr/bin/google-chrome";
const GO_DIR = join(process.cwd(), "..", "src-go");
let FAKECORE, SERVER;
const STATIC = join(process.cwd(), "..", "src-elm");

const home = mkdtempSync(join(tmpdir(), "alayaface-mc-"));
const port = 9231 + Math.floor(Math.random() * 200);
const env = { ...process.env, HOME: home };
console.log("HOME:", home, "port:", port);

// Built here rather than inherited from whichever script ran first: this
// suite asserts on fakecore's model_sync record, so it has to be THIS
// checkout's fakecore, not a stale binary left in bin/.
({ fakecore: FAKECORE, server: SERVER } = buildGoBinaries(join(process.cwd(), "..")));

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

const SYNC_FILE = join(home, ".alayaface", "presets", "Simple", "model_sync.last.json");
const fieldId = (key) => `#model-editor-${key}-default`;
const valueOf = (key) =>
  page.evaluate((sel) => {
    const el = document.querySelector(sel);
    return el ? el.value : null;
  }, fieldId(key));

let page;

async function openDefaultModelsEditor() {
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

  // Simple → Edit → Models
  await page.evaluate(() => {
    const row = [...document.querySelectorAll(".pm-row")].find((r) => r.querySelector(".pm-name")?.textContent === "Simple");
    [...row.querySelectorAll("button")].find((b) => b.textContent === "Edit").click();
  });
  await waitFor(() => page.evaluate(() => document.body.textContent.includes("Edit Simple:")), 15000, "Edit Simple panel");
  await page.evaluate(() => {
    const rows = [...document.querySelectorAll(".pm-edit-row")];
    const btn = rows.flatMap((r) => [...r.querySelectorAll("button")]).find((b) => b.textContent.trim() === "Models");
    btn.click();
  });
  await waitFor(() => page.evaluate(() => !!document.querySelector("#model-selector-input-default")), 15000, "default-models list");
}

async function editModel(id) {
  await page.evaluate((rowId) => {
    const row = document.querySelector(`#model-selector-item-default-${rowId}`);
    if (!row) throw new Error("no model row " + rowId);
    [...row.querySelectorAll("button")].find((b) => b.textContent.trim() === "Edit").click();
  }, id);
  await waitFor(() => page.evaluate(() => !!document.querySelector("#model-editor-serial_tool_calls-default")), 15000, "model editor form");
}

// Save is disabled iff a field reports a problem.
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
    // One input event carrying the whole string. Typing character by
    // character loses most of it: every keystroke makes Elm re-render and
    // re-assert the textarea's value, which clobbers whatever has not been
    // committed yet (observed as `{"thinking":` arriving as `{"`).
    await page.evaluate((s, v) => {
      const el = document.querySelector(s);
      const proto = el.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(proto, "value").set.call(el, v);
      el.dispatchEvent(new Event("input", { bubbles: true }));
    }, sel, value);
  }
  await waitFor(() => page.evaluate((s, v) => document.querySelector(s).value === v, sel, value), 10000, "field " + key + " to hold " + JSON.stringify(value))
    .catch(async (e) => {
      console.log("SETFIELD DIAG", key, JSON.stringify({
        want: value,
        got: await page.evaluate((s) => document.querySelector(s)?.value, sel),
        tag: await page.evaluate((s) => document.querySelector(s)?.tagName, sel),
      }));
      throw e;
    });
}

async function clickButton(text) {
  await page.evaluate((label) => {
    const b = [...document.querySelectorAll("button")].find((x) => x.textContent.trim() === label);
    if (!b) throw new Error("no button " + label);
    b.click();
  }, text);
}

function readSynced() {
  return JSON.parse(readFileSync(SYNC_FILE, "utf8"));
}

async function main() {
  await waitFor(async () => { try { await fetch(`http://127.0.0.1:${port}/rpc/list_presets`, { method: "POST" }); return true; } catch { return false; } });

  const browser = await puppeteer.launch({ executablePath: CHROME, headless: true, args: ["--no-sandbox", "--disable-gpu"] });
  page = await browser.newPage();
  await page.setViewport({ width: 1280, height: 900 });
  page.on("pageerror", (e) => console.log("[pageerror]", String(e).slice(0, 300)));
  await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: "networkidle0", timeout: 20000 });

  await openDefaultModelsEditor();
  await waitFor(() => page.evaluate(() => !!document.querySelector("#model-selector-item-default-2")), 15000, "model row 2");
  await editModel(2);

  // ── 1. every field has a control, carrying what model_list sent ──
  const expected = {
    name: "fake-model-2",
    protocol_type: "openai",
    base_url: "http://localhost:11434/v1",
    api_key: "fake",
    model_name: "model-2",
    context_limit: "16384",
    max_tokens: "4096",
    reasoning_field: "reasoning",
    reasoning_0: "",
    reasoning_1: '{"thinking":{"type":"enabled"}}',
    reasoning_2: '{"thinking":{"type":"enabled"},"effort":"max"}',
    serial_tool_calls: "true",
  };
  for (const [key, want] of Object.entries(expected)) {
    const got = await waitFor(() => valueOf(key).then((v) => (v === want ? v : null)), 8000, "field " + key + " = " + JSON.stringify(want))
      .catch(() => valueOf(key));
    console.log(`field ${key}: ${JSON.stringify(got)}`);
    if (got !== want) throw new Error(`field ${key} = ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
  }
  const labels = await page.evaluate(() => [...document.querySelectorAll(".me-field-label")].map((el) => el.textContent));
  console.log("labels:", JSON.stringify(labels));
  if (labels.length !== Object.keys(expected).length) {
    throw new Error(`editor shows ${labels.length} fields, want ${Object.keys(expected).length}`);
  }

  // Twelve fields need to scroll, and Save must stay reachable while doing so.
  const layout = await page.evaluate(() => {
    const f = document.querySelector(".me-fields");
    const a = document.querySelector(".me-actions");
    const card = document.querySelector(".overlay-card");
    if (!f || !a || !card) return null;
    const aRect = a.getBoundingClientRect(), cRect = card.getBoundingClientRect();
    return {
      overflow: f.scrollHeight > f.clientHeight,
      scrollable: getComputedStyle(f).overflowY === "auto",
      actionsVisible: aRect.bottom <= cRect.bottom + 1 && aRect.top >= cRect.top - 1,
    };
  });
  console.log("layout:", JSON.stringify(layout));
  if (!layout || !layout.scrollable || !layout.actionsVisible) throw new Error("model editor page clipped: " + JSON.stringify(layout));

  // ── 2. an unparsable provider block blocks Save, it does not vanish ──
  await setField("reasoning_1", '{"thinking":');
  if (!(await saveDisabled())) throw new Error("Save enabled with unparsable reasoning_1 JSON");
  const errs = await errorLines();
  console.log("field errors:", JSON.stringify(errs));
  if (!errs.some((e) => e.includes("reasoning_1") || e.includes("Reasoning"))) throw new Error("no reasoning_1 problem reported");
  await setField("reasoning_1", '{"thinking":{"type":"disabled"}}');
  if (await saveDisabled()) throw new Error("Save still disabled after fixing reasoning_1");

  // Edit the visible fields; everything else must survive untouched.
  await setField("name", "renamed-vllm");
  await setField("reasoning_field", "reasoning_content");
  await page.select(fieldId("serial_tool_calls"), "false");
  await waitFor(() => page.evaluate(() => document.querySelector("#model-editor-serial_tool_calls-default").value === "false"), 10000, "serial select to read false");
  await clickButton("Save");
  await waitFor(() => page.evaluate(() => !document.querySelector("#model-editor-name-default")), 10000, "editor to return to the list after Save");

  const title = await page.evaluate(() => {
    const row = document.querySelector("#model-selector-item-default-2");
    return row ? row.querySelector(".sel-page-item-name").textContent : null;
  });
  console.log("row 2 title after save:", title);
  if (title !== "renamed-vllm") throw new Error("edited name not in the list: " + title);

  // ── 3. sync, then read what AlayaCore actually received ──
  // The Preset Manager overlay is still open underneath this one, so
  // `.card-close` is not unique: the LAST one is the model editor's (it
  // renders on top). Clicking the first closes the Preset Manager instead
  // and the sync prompt never appears.
  await page.evaluate(() => {
    const closes = [...document.querySelectorAll(".card-close")];
    closes[closes.length - 1].click();
  });
  await waitFor(() => page.evaluate(() => document.body.textContent.includes("Sync & Close")), 15000, "sync prompt");
  await clickButton("Sync & Close");
  const synced = await waitFor(() => { try { return readSynced(); } catch { return null; } }, 15000, "fakecore to record model_sync");
  console.log("synced payload:", JSON.stringify(synced));

  const edited = synced.find((m) => m.name === "renamed-vllm");
  if (!edited) throw new Error("edited entry missing from the sync payload");
  const untouched = synced.find((m) => m.name === "fake-model-1");
  if (!untouched) throw new Error("untouched entry missing from the sync payload");

  const check = (cond, msg) => { if (!cond) throw new Error(msg); };
  check(edited.reasoning_field === "reasoning_content", "edited reasoning_field lost");
  check(edited.serial_tool_calls === false, "edited serial_tool_calls lost");
  check(edited.reasoning_1 && edited.reasoning_1.thinking.type === "disabled", "fixed reasoning_1 lost");
  check(edited.reasoning_2 && edited.reasoning_2.effort === "max", "untouched reasoning_2 lost");
  check(edited.context_limit === 16384 && edited.max_tokens === 4096, "untouched numeric limits lost");
  check(edited.quantization === "awq", "the un-modelled key quantization was deleted by the edit");
  check(untouched.serial_tool_calls === false, "serial_tool_calls not stated for the untouched entry");
  check(untouched.reasoning_field === "", "reasoning_field not stated for the untouched entry");
  console.log("ALL PASS");

  await browser.close();
}

main().catch((e) => { console.error("FAIL:", e.message); process.exitCode = 1; })
  .finally(() => { server.kill("SIGKILL"); setTimeout(() => rmSync(home, { recursive: true, force: true }), 500); });

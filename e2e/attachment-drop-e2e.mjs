// Attachment drag-drop E2E: opens the app in headless Chrome, creates a
// session, then simulates an OS file drop onto the prompt input
// (dragenter/dragover/drop with a DataTransfer carrying File objects).
// Asserts the drop highlight toggles, the files are read to data URIs
// by transport.js, staged as chips (media type detected from the name),
// and a too-large file is rejected with a status message.
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

const home = mkdtempSync(join(tmpdir(), "alayaface-drop-"));
const port = 9301 + Math.floor(Math.random() * 200);
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

  const browser = await puppeteer.launch({ executablePath: CHROME, headless: true, args: ["--no-sandbox", "--disable-gpu"] });
  const page = await browser.newPage();
  await page.setViewport({ width: 1280, height: 860 });
  page.on("pageerror", (e) => console.log("[pageerror]", String(e).slice(0, 300)));
  page.on("console", (m) => { if (m.type() === "error") console.log("[console.error]", m.text().slice(0, 200)); });
  await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: "networkidle0", timeout: 20000 });

  // Create a session: right-click canvas → New Session → Simple.
  await page.mouse.click(400, 300, { button: "right" });
  await waitFor(() => page.evaluate(() => [...document.querySelectorAll(".global-menu-item")].some((el) => el.textContent.includes("New Session"))));
  await page.evaluate(() => [...document.querySelectorAll(".global-menu-item")].find((el) => el.textContent.includes("New Session")).click());
  await waitFor(() => page.evaluate(() => !!document.querySelector(".global-menu-submenu-item")));
  await page.evaluate(() => [...document.querySelectorAll(".global-menu-submenu-item")].find((el) => el.textContent.trim() === "Simple").click());
  await waitFor(() => page.evaluate(() => !!document.querySelector(".session-panel .input-container")), 20000);
  console.log("  ✓ session created with an input container");

  // Simulate dragging a file over the input container: the highlight
  // class must appear, then the drop stages the attachment.
  const dropResult = await page.evaluate(() => {
    const container = document.querySelector(".session-panel .input-container");
    const dt = new DataTransfer();
    dt.items.add(new File(["hello"], "photo.png", { type: "image/png" }));
    const fire = (type, target) => {
      const ev = new DragEvent(type, { bubbles: true, cancelable: true, dataTransfer: dt });
      target.dispatchEvent(ev);
      return ev.defaultPrevented;
    };
    const enterPrevented = fire("dragenter", container);
    const highlightOn = container.classList.contains("input-drop-active");
    const overPrevented = fire("dragover", container);
    fire("drop", container);
    const highlightOff = !container.classList.contains("input-drop-active");
    return { enterPrevented, overPrevented, highlightOn, highlightOff };
  });
  console.log("drop events:", JSON.stringify(dropResult));
  assert(dropResult.enterPrevented && dropResult.overPrevented, "dragenter/dragover prevented (drop allowed)");
  assert(dropResult.highlightOn && dropResult.highlightOff, "drop highlight toggles on dragenter and clears on drop");

  // The file is read to a data URI and staged as a chip.
  await waitFor(() => page.evaluate(() => {
    const chip = document.querySelector(".hs-staged-chip");
    return chip && chip.textContent.includes("photo.png");
  }), 10000);
  const chipInfo = await page.evaluate(() => {
    const chip = document.querySelector(".hs-staged-chip");
    return {
      text: chip.textContent,
      icon: chip.querySelector(".hs-staged-icon") ? chip.querySelector(".hs-staged-icon").textContent : "",
    };
  });
  console.log("staged chip:", JSON.stringify(chipInfo));

  // Multi-file drop with one oversized file: good files stage, the
  // oversized one is rejected with a status message.
  const multi = await page.evaluate(() => {
    const container = document.querySelector(".session-panel .input-container");
    const dt = new DataTransfer();
    dt.items.add(new File(["clip"], "clip.mp3", { type: "audio/mpeg" }));
    dt.items.add(new File(["x"], "notes.txt", { type: "text/plain" }));
    const fire = (type) => { const ev = new DragEvent(type, { bubbles: true, cancelable: true, dataTransfer: dt }); container.dispatchEvent(ev); };
    fire("dragenter");
    fire("dragover");
    fire("drop");
    return true;
  });
  await waitFor(() => page.evaluate(() => document.querySelectorAll(".hs-staged-chip").length === 3), 10000);
  const chips = await page.evaluate(() => [...document.querySelectorAll(".hs-staged-chip .hs-staged-name")].map((el) => el.textContent));
  assert(chips.join(",") === "photo.png,clip.mp3,notes.txt", "multi-file drop stages all files: " + chips.join(","));

  // The oversized file (over the 64 MiB JS cap) is rejected and an
  // error message appears in the session display, while the accepted
  // file still stages.
  const oversized = await page.evaluate(() => {
    const container = document.querySelector(".session-panel .input-container");
    const dt = new DataTransfer();
    // A genuinely 128 MiB file (size must exceed the 64 MiB cap).
    const big = new File([new Uint8Array(128 * 1024 * 1024)], "huge.bin", { type: "application/octet-stream" });
    dt.items.add(big);
    const fire = (type) => { const ev = new DragEvent(type, { bubbles: true, cancelable: true, dataTransfer: dt }); container.dispatchEvent(ev); return ev.defaultPrevented; };
    const enterP = fire("dragenter");
    const hlOn = container.classList.contains("input-drop-active");
    const overP = fire("dragover");
    fire("drop");
    const hlOff = !container.classList.contains("input-drop-active");
    return { files: dt.files.length, size: dt.files.length ? dt.files[0].size : 0, enterP, overP, hlOn, hlOff };
  });
  console.log("oversized drop events:", JSON.stringify(oversized));
  await waitFor(() => page.evaluate(() => {
    const err = document.querySelector(".message-error");
    return err && err.textContent.includes("Drop failed");
  }), 10000);
  const errText = await page.evaluate(() => document.querySelector(".message-error").textContent);
  console.log("drop error message:", errText);
  assert(errText.includes("huge.bin") && errText.includes("64 MiB"), "oversized file rejected with an error message");
  const chipCount = await page.evaluate(() => document.querySelectorAll(".hs-staged-chip").length);
  assert(chipCount === 3, "no chip added for the rejected file");

  await browser.close();
  console.log("ALL PASS");
}

main()
  .catch((e) => { console.error(e); process.exitCode = 1; })
  .finally(() => {
    server.kill("SIGTERM");
    setTimeout(() => { try { rmSync(home, { recursive: true, force: true }); } catch {} }, 500);
  });

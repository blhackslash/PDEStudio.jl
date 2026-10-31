// Drives the studio served by browser_tests.jl in headless Chromium: real mouse clicks on the Makie widgets and the
// browser's file chooser. Julia writes its state to $PDESTUDIO_E2E_DIR/state.json; this script writes one result per
// step to results.json (browser_tests.jl turns them into tests).
const { chromium } = require("playwright-core");
const fs = require("fs"), path = require("path");
const DIR = process.env.PDESTUDIO_E2E_DIR, URL = process.env.PDESTUDIO_E2E_URL, FILES = path.join(DIR, "files");
const state = () => { try { return JSON.parse(fs.readFileSync(path.join(DIR, "state.json"), "utf8")); } catch { return null; } };
const sleep = (ms) => new Promise(r => setTimeout(r, ms));
async function until(desc, pred, timeout = 30000) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeout) { const s = state(); if (s && pred(s)) { return s; } await sleep(200); }
  throw new Error("timed out: " + desc + " | status line: " + (state() || {}).status);
}
const results = [];
async function step(name, f) {
  try { await f(); results.push({ step: name, ok: true, message: "" }); console.log("  ok  ", name); }
  catch (e) { results.push({ step: name, ok: false, message: e.message }); console.log("  FAIL", name, "|", e.message); }
}
// Browse… as if clicked long ago: Julia calls Browse… itself. Nothing may touch the page in between, since
// Playwright's evaluate counts as a user gesture (user activation).
async function browseWithoutGesture() {
  await sleep(6000);   // the activation of the last click has expired
  fs.writeFileSync(path.join(DIR, "cmd"), "browse");
  await sleep(2000);
}

(async () => {
  const chromiumPath = process.env.PDESTUDIO_CHROMIUM || undefined;   // default: Playwright's own Chromium
  const browser = await chromium.launch({ executablePath: chromiumPath,
    args: ["--no-sandbox", "--use-angle=swiftshader", "--enable-unsafe-swiftshader"] });
  const page = await browser.newPage({ viewport: { width: 1700, height: 1000 } });
  page.on("pageerror", e => console.log("  [pageerror]", e.message));
  await page.goto(URL);
  // a real click at the centre of a widget's bounding box (Makie: origin bottom left)
  async function click(key) {
    const s = state(), [x, y, w, h] = s[key];
    const r = await page.evaluate(() => { const b = document.querySelector("canvas").getBoundingClientRect(); return [b.left, b.top, b.height]; });
    const k = r[2] / s.fig_height;
    await page.mouse.click(r[0] + (x + w / 2) * k, r[1] + (s.fig_height - y - h / 2) * k);
  }
  const drop = (files) => page.evaluate((files) => {
    const dt = new DataTransfer();
    for (const [name, text] of files) { dt.items.add(new File([text], name)); }
    const c = document.querySelector("canvas");
    c.dispatchEvent(new DragEvent("dragover", { dataTransfer: dt, bubbles: true, cancelable: true }));
    c.dispatchEvent(new DragEvent("drop", { dataTransfer: dt, bubbles: true, cancelable: true }));
  }, files);

  await step("the extension connects to the browser session", async () => {
    await page.waitForSelector("canvas", { timeout: 120000 });
    await until("session connected", s => s.sessions >= 1, 120000);
    await click("tab_files");
    await sleep(500);
  });
  await step("a CSV dropped onto the window is uploaded and loaded", async () => {
    await drop([["plain.csv", fs.readFileSync(path.join(FILES, "plain.csv"), "utf8")]]);
    await until("plain.csv loaded", s => s.N === 40 && /Loaded plain\.csv/.test(s.status));
  });
  await step("a file dropped next to the studio doesn't replace the page", async () => {
    const prevented = await page.evaluate(() => {
      const dt = new DataTransfer(); dt.items.add(new File(["x"], "x.csv"));
      const e = new DragEvent("drop", { dataTransfer: dt, bubbles: true, cancelable: true });
      document.body.dispatchEvent(e); return e.defaultPrevented;
    });
    if (!prevented) { throw new Error("the drop on the page was not prevented"); }
  });
  await step("Browse… opens the file chooser; a CSV with its sources asks first, then Load runs them", async () => {
    const [chooser] = await Promise.all([page.waitForEvent("filechooser", { timeout: 15000 }), click("browse")]);
    if (!chooser.isMultiple()) { throw new Error("the chooser doesn't allow several files"); }
    const src = path.join(FILES, "exp2_sources");
    await chooser.setFiles([path.join(FILES, "exp2.csv"), ...fs.readdirSync(src).map(f => path.join(src, f))]);
    const s = await until("second click requested", s => /click Load again/.test(s.status));
    if (!s.path_box.endsWith("exp2.csv")) { throw new Error("path box: " + s.path_box); }
    await click("load");
    await until("exp2 loaded with its sources", s => s.N === 24 && s.source_failures.length === 0 && /Loaded exp2/.test(s.status));
  });
  await step("without a recent click a panel asks for one; Choose file… opens the chooser", async () => {
    await browseWithoutGesture();
    const panel = page.getByText("Load a configuration (CSV or Julia file):");
    if (!(await panel.isVisible())) { throw new Error("the panel is not shown"); }
    const [chooser] = await Promise.all([page.waitForEvent("filechooser", { timeout: 15000 }),
                                         page.getByText("Choose file…").click()]);
    await chooser.setFiles([path.join(FILES, "plain.csv")]);
    await until("plain.csv loaded again", s => s.N === 40 && /Loaded plain\.csv/.test(s.status));
  });
  await step("Cancel on the panel reports that no file was chosen", async () => {
    await browseWithoutGesture();
    await page.getByText("Cancel", { exact: true }).click({ timeout: 15000 });
    await until("cancelled", s => s.status === "No file chosen.");
  });
  await step("an upload without a single configuration is refused", async () => {
    await drop([["a.jl", "a() = 1"], ["b.jl", "b() = 1"]]);
    await until("refused", s => /Upload one configuration/.test(s.status));
  });
  await browser.close();
})().catch(e => { results.push({ step: "driver", ok: false, message: String(e && e.stack || e) }); console.log(e); })
  .finally(() => fs.writeFileSync(path.join(DIR, "results.json"), JSON.stringify(results)));

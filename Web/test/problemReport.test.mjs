// Report a Problem (#3718): the page's client line and its browser in a few words.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { load } from "./load.mjs";

const p = await load("src/model/problemReport.ts");

test("the client line names the host that serves the page", () => {
  assert.equal(p.webClient("0.17.0"), "Web page (served by Agents 0.17.0)");
  assert.equal(p.webClient(undefined), "Web page");
});

test("the browser in a few words", () => {
  const mac = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko)";
  assert.equal(p.browserWords(`${mac} Chrome/156.0.0.0 Safari/537.36`), "Chrome 156 on macOS");
  assert.equal(p.browserWords(`${mac} HeadlessChrome/156.0.0.0 Safari/537.36`), "Chrome 156 on macOS");
  assert.equal(p.browserWords(`${mac} Chrome/156.0.0.0 Safari/537.36 Edg/156.0.0.0`), "Edge 156 on macOS");
  assert.equal(p.browserWords("Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:140.0) Gecko/20100101 Firefox/140.0"), "Firefox 140 on macOS");
  assert.equal(p.browserWords("Mozilla/5.0 (iPhone; CPU iPhone OS 19_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/19.0 Mobile/15E148 Safari/604.1"), "Safari 19.0 on iOS");
  assert.equal(p.browserWords("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0 Safari/537.36"), "Chrome 150 on Linux");
  assert.equal(p.browserWords("SomethingElse/1"), "SomethingElse/1");
});

test("the person menu has Report a Problem…, and the columns draw its dialog", () => {
  const top = readFileSync(new URL("../src/views/TopBar.tsx", import.meta.url), "utf8");
  const columns = readFileSync(new URL("../src/views/Columns.tsx", import.meta.url), "utf8");
  assert.match(top, />Report a Problem…<\/button>/);
  assert.match(columns, /<ReportProblemDialog store=\{store\} \/>/);
});

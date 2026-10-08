// Web/dist is what this source builds (spec 071 FR-035a, research R8). The Swift side,
// WebDistManifestTests, checks the same manifest without Node. Web/dist is not checked in
// (#473): with none built yet, scripts/web.sh build makes one, there is nothing to check.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repo = dirname(dirname(dirname(fileURLToPath(import.meta.url))));
const manifestPath = join(repo, "Web/dist/MANIFEST");
const skip = existsSync(manifestPath) ? false : "no Web/dist built here; run scripts/web.sh build";
const manifest = skip ? [] : readFileSync(manifestPath, "utf8").trim().split("\n");

test("every file in the manifest has the bytes it records", { skip }, () => {
  const entries = manifest.filter((line) => /^(src|out) /.test(line));
  assert.ok(entries.some((line) => line.startsWith("out ")), "the manifest lists outputs");
  for (const line of entries) {
    const [, hash, path] = line.split(" ");
    const actual = createHash("sha256").update(readFileSync(join(repo, path))).digest("hex");
    assert.equal(actual, hash, `${path} differs from Web/dist/MANIFEST; run scripts/web.sh build`);
  }
});

test("the manifest names the Node and esbuild it was built with", { skip }, () => {
  assert.match(manifest[0] ?? "", /^agents-web 1$/);
  assert.equal(manifest[1], `node v${readFileSync(join(repo, "Web/.node-version"), "utf8").trim()}`);
  assert.match(manifest[2] ?? "", /^esbuild \d+\.\d+\.\d+$/);
});

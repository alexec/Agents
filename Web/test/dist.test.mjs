// Web/dist is what its build wrote (spec 071 FR-035a, research R8). The Swift side,
// WebDistManifestTests, checks the same manifest without Node. Only the built files are held
// to it: a pull request leaves Web/dist alone, so a source newer than the bundle is not a
// failure; main rebuilds and commits it after the merge (#473, web-dist.yml).
import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repo = dirname(dirname(dirname(fileURLToPath(import.meta.url))));
const manifest = readFileSync(join(repo, "Web/dist/MANIFEST"), "utf8").trim().split("\n");

test("every built file in the manifest has the bytes it records", () => {
  const entries = manifest.filter((line) => line.startsWith("out "));
  assert.ok(entries.length > 0, "the manifest lists outputs");
  for (const line of entries) {
    const [, hash, path] = line.split(" ");
    const actual = createHash("sha256").update(readFileSync(join(repo, path))).digest("hex");
    assert.equal(actual, hash, `${path} differs from Web/dist/MANIFEST; run scripts/web.sh build`);
  }
});

test("the manifest names the Node and esbuild it was built with", () => {
  assert.match(manifest[0] ?? "", /^agents-web 1$/);
  assert.equal(manifest[1], `node v${readFileSync(join(repo, "Web/.node-version"), "utf8").trim()}`);
  assert.match(manifest[2] ?? "", /^esbuild \d+\.\d+\.\d+$/);
});

// Builds the web remote into dist/, the same bytes every time, and writes dist/MANIFEST
// (spec 071, research R8).
//
// dist/ is not checked in (#473): Agents Host's build runs scripts/web.sh dist first. MANIFEST
// holds a hash of every source input and every output: WebDistManifestTests (Swift, no Node)
// fails when a source changed without a rebuild or dist was edited by hand. The control plane
// serves only what MANIFEST lists.

import { createHash } from "node:crypto";
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import * as esbuild from "esbuild";

const web = dirname(fileURLToPath(import.meta.url));
const repo = dirname(web);
const dist = join(web, "dist");

// One Node, so one esbuild and one set of bytes. CI reads the same file.
const wanted = readFileSync(join(web, ".node-version"), "utf8").trim();
if (process.versions.node !== wanted) {
  console.error(`build: Node ${wanted} is wanted (Web/.node-version), this is ${process.versions.node}`);
  process.exit(1);
}

// The files whose bytes decide dist's. Keep in step with WebDistManifestTests.inputs.
const fixedInputs = ["index.html", "sandbox.html", "build.mjs", "tsconfig.json", "package.json", "package-lock.json", ".node-version"];
const inputFolders = ["src", "assets"];

function files(folder) {
  if (!existsSync(folder)) return [];
  // Dotfiles (a Finder .DS_Store) are neither inputs nor outputs.
  return readdirSync(folder).filter((name) => !name.startsWith(".")).flatMap((name) => {
    const path = join(folder, name);
    return statSync(path).isDirectory() ? files(path) : [path];
  });
}

const sha256 = (path) => createHash("sha256").update(readFileSync(path)).digest("hex");
const repoPath = (path) => relative(repo, path).split("\\").join("/");
const byPath = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

rmSync(dist, { recursive: true, force: true });
mkdirSync(dist);

const common = {
  bundle: true,
  minify: true,
  sourcemap: false,
  legalComments: "eof",
  charset: "utf8",
  target: ["safari18", "chrome130", "firefox130"],
  logLevel: "warning",
  absWorkingDir: web,
};
await esbuild.build({
  ...common,
  entryPoints: ["src/main.tsx"],
  outfile: "dist/app.js",
  format: "esm",
  jsx: "automatic",
  jsxImportSource: "preact",
});
await esbuild.build({ ...common, entryPoints: ["src/app.css"], outfile: "dist/app.css" });
// The sandbox proxy a view is drawn through (#187), served at another origin than the page.
await esbuild.build({ ...common, entryPoints: ["src/sandbox/proxy.ts"], outfile: "dist/sandbox.js", format: "iife" });
cpSync(join(web, "index.html"), join(dist, "index.html"));
cpSync(join(web, "sandbox.html"), join(dist, "sandbox.html"));
if (existsSync(join(web, "assets"))) cpSync(join(web, "assets"), join(dist, "assets"), { recursive: true });

const inputs = [...fixedInputs.map((name) => join(web, name)), ...inputFolders.flatMap((name) => files(join(web, name)))]
  .filter((path) => existsSync(path))
  .map(repoPath)
  .sort(byPath);
const outputs = files(dist).map(repoPath).sort(byPath);

const lines = [
  "agents-web 1",
  `node v${process.versions.node}`,
  `esbuild ${esbuild.version}`,
  ...inputs.map((path) => `src ${sha256(join(repo, path))} ${path}`),
  ...outputs.map((path) => `out ${sha256(join(repo, path))} ${path}`),
];
writeFileSync(join(dist, "MANIFEST"), lines.join("\n") + "\n");
console.log(`build: ${outputs.length} files in Web/dist, ${inputs.length} inputs in MANIFEST`);

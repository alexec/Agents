// Bundles a TypeScript entry with esbuild in memory and imports it, for node --test.
import { build } from "esbuild";
import { fileURLToPath } from "node:url";

const web = fileURLToPath(new URL("..", import.meta.url));

let loads = 0;

export async function load(entry) {
  const { outputFiles } = await build({ entryPoints: [entry], bundle: true, format: "esm", write: false,
    absWorkingDir: web, platform: "neutral", mainFields: ["module", "main"], logLevel: "silent" });
  // A comment of its own each time, so a module that reads the page at its start is run afresh.
  return import("data:text/javascript," + encodeURIComponent(outputFiles[0].text + `\n// ${++loads}`));
}

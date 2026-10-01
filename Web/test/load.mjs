// Bundles a TypeScript entry with esbuild in memory and imports it, for node --test.
import { build } from "esbuild";
import { fileURLToPath } from "node:url";

const web = fileURLToPath(new URL("..", import.meta.url));

export async function load(entry) {
  const { outputFiles } = await build({ entryPoints: [entry], bundle: true, format: "esm", write: false,
    absWorkingDir: web, platform: "neutral", logLevel: "silent" });
  return import("data:text/javascript," + encodeURIComponent(outputFiles[0].text));
}

// Every package the web remote is built from carries a licence we can ship (research R9).
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const web = dirname(dirname(fileURLToPath(import.meta.url)));
const lock = JSON.parse(readFileSync(join(web, "package-lock.json"), "utf8"));
// PSF-2.0 is argparse, which markdown-it needs only for its command line; it is never bundled.
const allowed = /^(MIT|ISC|BSD-2-Clause|BSD-3-Clause|0BSD|Apache-2\.0|PSF-2\.0)$/;
const refused = Object.entries(lock.packages)
  .filter(([path]) => path !== "")
  .filter(([, entry]) => !allowed.test(entry.license ?? ""))
  .map(([path, entry]) => `${path}: ${entry.license ?? "no licence"}`);
if (refused.length) {
  console.error("licences: not on the list (MIT, ISC, BSD, Apache-2.0, PSF-2.0):\n" + refused.join("\n"));
  process.exit(1);
}
console.log(`licences: ${Object.keys(lock.packages).length - 1} packages, all allowed`);

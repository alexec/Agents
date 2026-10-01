// Keeps agent output inert and the page to its own origin (spec 071 FR-030, FR-031, FR-034;
// research R12). Run by `npm run check` and by CI's web job.
//
// Our own source may not touch an HTML sink or build code from strings. Preact's bundle
// itself holds an `innerHTML` assignment, reached only through `dangerouslySetInnerHTML`,
// which the source rule bans; Chrome's Trusted Types policy (`trusted-types 'none'`) would
// refuse it at run time as well. The built files may not evaluate strings, load from
// another origin, or carry inline script or style.

import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const web = dirname(dirname(fileURLToPath(import.meta.url)));
const failures = [];

function files(folder) {
  if (!existsSync(folder)) return [];
  return readdirSync(folder).flatMap((name) => {
    const path = join(folder, name);
    return statSync(path).isDirectory() ? files(path) : [path];
  });
}

function scan(path, rules) {
  const text = readFileSync(path, "utf8");
  for (const [pattern, why] of rules) {
    for (const match of text.matchAll(pattern)) {
      const line = text.slice(0, match.index).split("\n").length;
      failures.push(`${relative(web, path)}:${line}: ${why} (${match[0].slice(0, 60)})`);
    }
  }
}

// Namespace names and licence links are strings, never fetched.
const allowedURLs = new Set([
  "http://www.w3.org/1998/Math/MathML",
  "http://www.w3.org/1999/xhtml",
  "http://www.w3.org/2000/svg",
  "http://www.w3.org/1999/xlink",
  "http://www.w3.org/XML/1998/namespace",
]);
const strings = [
  [/\beval\s*\(/g, "no eval"],
  [/\bnew\s+Function\b/g, "no new Function"],
  [/\bset(?:Timeout|Interval)\s*\(\s*["'`]/g, "no timers from strings"],
];
const sinks = [
  [/\b(?:inner|outer)HTML\b/g, "no HTML sinks"],
  [/\binsertAdjacentHTML\b/g, "no HTML sinks"],
  [/\bdocument\.write(?:ln)?\b/g, "no document.write"],
  [/\bdangerouslySetInnerHTML\b/g, "no raw HTML through Preact"],
  [/\bcreateContextualFragment\b|\bDOMParser\b/g, "no HTML parsing"],
  [/\bimportScripts\b|\bimport\s*\(\s*[^"'`]/g, "no loading code at run time"],
];

for (const path of files(join(web, "src"))) {
  scan(path, [...strings, ...sinks, [/https?:\/\/[^\s"'`)]+/g, "no addresses in source; the page reaches only its own origin"]]);
}

for (const path of files(join(web, "dist"))) {
  if (path.endsWith(".js") || path.endsWith(".css")) {
    scan(path, strings);
    const text = readFileSync(path, "utf8");
    for (const match of text.matchAll(/(?:https?:)?\/\/[a-z0-9.-]+\.[a-z]{2,}[^\s"'`)]*/gi)) {
      const url = match[0];
      if (allowedURLs.has(url)) continue;
      // Licence comments name their homes; they are comments, not requests.
      const before = text.lastIndexOf("/*", match.index), after = text.lastIndexOf("*/", match.index);
      if (before > after) continue;
      failures.push(`${relative(web, path)}: an address outside the allowlist (${url.slice(0, 80)})`);
    }
    if (path.endsWith(".css") && /@import|url\(\s*["']?(?:https?:)?\/\//i.test(text)) {
      failures.push(`${relative(web, path)}: CSS may not load from another origin`);
    }
  }
  if (path.endsWith(".html")) {
    const html = readFileSync(path, "utf8");
    for (const tag of html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)) {
      if (!/\bsrc\s*=\s*"\/[^"/][^"]*"/.test(tag[0]) || tag[1].trim()) failures.push(`${relative(web, path)}: inline or foreign script`);
    }
    if (/<style\b|\sstyle\s*=|\son[a-z]+\s*=/i.test(html)) failures.push(`${relative(web, path)}: inline style or handler`);
    for (const ref of html.matchAll(/\b(?:src|href)\s*=\s*"([^"]*)"/gi)) {
      if (!ref[1].startsWith("/") || ref[1].startsWith("//")) failures.push(`${relative(web, path)}: ${ref[1]} is not on this origin`);
    }
  }
}

if (failures.length) {
  console.error(failures.join("\n"));
  process.exit(1);
}
console.log("lint: src and dist are clean");

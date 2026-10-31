// Keeps agent output inert and the page to its own origin (spec 071 FR-030 to FR-032, FR-034;
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

function scan(path, rules, { allowMarked = false } = {}) {
  const text = readFileSync(path, "utf8");
  const lines = text.split("\n");
  for (const [pattern, why] of rules) {
    for (const match of text.matchAll(pattern)) {
      if (allowedURLs.has(match[0])) continue;
      const line = text.slice(0, match.index).split("\n").length;
      // A single, reviewed exception (FR-030–032): the line right above names the issue
      // and why, so an exception is never silent, and it bypasses only `ambient`'s rules,
      // never eval, an HTML sink, or loading code at run time.
      if (allowMarked && lines[line - 2]?.includes(allowExceptionMarker)) continue;
      failures.push(`${relative(web, path)}:${line}: ${why} (${match[0].slice(0, 60)})`);
    }
  }
}

// Namespace names, licence links and a field's example text are strings, never fetched.
const allowedURLs = new Set([
  // Clone Git URL…'s placeholder, the window's own (CloneSheet, #115).
  "https://github.com/owner/repository.git",
  // Help (#1327): the docs site at its own domain (#1549), a link the person opens in a new tab,
  // never fetched by the page.
  "https://docs.agentloops.dev/",
  // Repositories on github.com (#1685): where the person changes which repositories the GitHub
  // App reaches, the same for every person, as the window's; a link opened in a new tab, never fetched.
  "https://github.com/settings/installations",
  // Reports ▸ Value and the Lineage pane (#2998): an issue's, a PR's or a milestone's page on GitHub,
  // as the window's, a link the person opens in a new tab, never fetched.
  "https://github.com/",
  // Connect GitLab (#1630): the address field's example, and Make a Token's page with no address,
  // a link the person opens in a new tab, never fetched.
  "https://gitlab.com",
  // The wait card's link to the merge request or issue its arguments name (#3077): a link
  // the person opens in a new tab, never fetched.
  "https://gitlab.com/",
  // Connect Linear (#1343): the hand-back page, the one origin whose postMessage the page takes.
  "https://oauth.agentloops.dev",
  // Console ▸ Sign-In (#1002): each preset's issuer, as a field's example text; the control plane reads the
  // issuer's discovery document, never the page.
  "https://acme.okta.com",
  "https://login.microsoftonline.com/TENANT-ID/v2.0",
  "https://accounts.google.com",
  "https://sso.example.com",
  "http://www.w3.org/1998/Math/MathML",
  "http://www.w3.org/1999/xhtml",
  "http://www.w3.org/2000/svg",
  "http://www.w3.org/1999/xlink",
  "http://www.w3.org/XML/1998/namespace",
  // The listener's own two origins (#187): the page at the name, and the views' sandbox proxy at
  // the address, which MCP Apps requires be another origin than the page's. Same port, same Mac.
  "http://localhost:${location.port}",
  "http://127.0.0.1:${location.port}",
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
// FR-032: no ambient credential, and nothing but the one WebSocket to talk on. A line
// marked `// lint:allow fetch` just above it may still make one same-origin request with
// no credential of its own (#2235: a refusal's words, read from `/readyz` since a closed
// WebSocket carries none a browser exposes); the comment above that says why.
const allowExceptionMarker = "lint:allow fetch";
const ambient = [
  [/\bdocument\.cookie\b|\bcredentials\s*:/g, "no cookies or ambient credentials"],
  [/\bfetch\s*\(|\bXMLHttpRequest\b|\bsendBeacon\b|\bEventSource\b/g, "no requests but the page's own WebSocket"],
];

for (const path of files(join(web, "src"))) {
  scan(path, [...strings, ...sinks]);
  scan(path, ambient, { allowMarked: true });
  scan(path, [[/https?:\/\/[^\s"'`)]+/g, "no addresses in source; the page reaches only its own origin"]]);
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

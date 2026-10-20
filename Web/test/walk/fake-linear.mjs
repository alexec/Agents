// A stand-in for Linear's GraphQL API, for the #1343 walk: it answers each query by its
// operation name from Go/internal/linearmcp/testdata, and an empty list for the rest. It holds
// no real data and needs no key.
//
//   node Web/test/walk/fake-linear.mjs <port>

import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const port = Number(process.argv[2] ?? 8799);
const data = fileURLToPath(new URL("../../../Go/internal/linearmcp/testdata/", import.meta.url));
const empty = { data: { issues: { nodes: [], pageInfo: { hasNextPage: false } }, comments: { nodes: [], pageInfo: { hasNextPage: false } } } };

createServer((req, res) => {
  let body = "";
  req.on("data", (c) => { body += c; });
  req.on("end", () => {
    const name = /^\s*query (\w+)/.exec(JSON.parse(body || "{}").query ?? "")?.[1] ?? "";
    let answer;
    try { answer = readFileSync(`${data}${name}.json`, "utf8"); } catch { answer = JSON.stringify(empty); }
    if (!["OpenIssues", "Teams"].includes(name)) answer = JSON.stringify(empty);
    console.log(`${new Date().toISOString()} ${name} ${req.headers.authorization ? "with a key" : "no key"}`);
    res.writeHead(200, { "content-type": "application/json" }).end(answer);
  });
}).listen(port, "127.0.0.1", () => console.log(`fake Linear on http://127.0.0.1:${port}`));

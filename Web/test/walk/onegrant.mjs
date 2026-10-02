// One grant for every paired client (#111): pairs a phone-kind client over the control
// plane's TLS address and a browser-kind client through the web remote's loopback listener,
// each with a fresh `agents-control code --client` (add `--browser` for the browser's), and has
// each ask what only an operator could before: the control plane's clients, a pairing code,
// a host code, and on the Mac's host the helper limits (#64), a folder outside any project
// and the client permissions. Prints what each call answered. Scratch roots only.
//
//   node Web/test/walk/onegrant.mjs <CONTROL_URL> <client code> <WEB_URL> <browser code> <project folder>

import { load } from "../load.mjs";

process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0"; // the scratch copy's self-signed certificate
const w = await load("test/wire.ts");

const [controlURL, phoneCode, webURL, browserCode, folder] = process.argv.slice(2);

/** Pairs as `kind` at `base`, then connects again as itself; returns a raw line client. */
async function paired(base, codeText, kind, name) {
  const origin = new URL(base).origin;
  const url = base.replace(/^http/, "ws").replace(/\/$/, "") + "/v1/connect";
  const code = w.parseCode(codeText);
  if (!code) throw new Error("not a client code");
  const keys = new w.MemoryKeyStore();
  let socket = await opened(url, origin);
  await w.pair(linesOf(socket), code, origin, name, async () => {
    const { pair, publicRaw } = await w.makeKeyPair();
    const client = w.newClientID();
    keys.record = { privateKey: pair.privateKey, publicKey: pair.publicKey, client,
      control: w.base64url(code.controlKey), paired: "" };
    return { client, publicRaw };
  }, undefined, kind);
  socket.close();
  socket = await opened(url, origin);
  const lines = linesOf(socket);
  await w.connect(lines, keys.record, origin, undefined, kind);
  let id = 0;
  return {
    client: keys.record.client,
    /** `host` is a host's id, or null for the control plane. Resolves with the reply's result or error. */
    async ask(method, params = {}, host = null) {
      id += 1;
      const m = { jsonrpc: "2.0", id, method, params };
      socket.send(JSON.stringify(host ? { h: host, m } : { m }));
      for (;;) {
        const frame = JSON.parse(await lines.next(15_000));
        const reply = typeof frame.m === "string" ? JSON.parse(frame.m) : frame.m;
        if (reply?.id === id) return reply.error ? { error: reply.error } : { result: reply.result };
      }
    },
    close() { socket.close(); },
  };
}

/** With the page's Origin, as a browser sends it: the loopback listener refuses a socket without one. */
function opened(url, origin) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url, { headers: { Origin: origin } });
    socket.onopen = () => resolve(socket);
    socket.onerror = (event) => reject(new Error(`could not open ${url}: ${event.message ?? "error"}`));
  });
}

function linesOf(socket) {
  const lines = new w.Lines(socket);
  socket.onmessage = (event) => lines.push(String(event.data));
  socket.onclose = () => lines.end(new Error("closed"));
  return lines;
}

const brief = (answer) => {
  if (answer.error) return `REFUSED ${answer.error.code} ${answer.error.message}`;
  const text = JSON.stringify(answer.result);
  return "ok " + (text.length > 110 ? text.slice(0, 110) + "…" : text);
};

let refused = 0;
for (const [label, base, code, kind] of [["phone (iPhone, TLS)", controlURL, phoneCode, "iPhone"],
                                          ["browser (loopback)", webURL, browserCode, "browser"]]) {
  const c = await paired(base, code, kind, `onegrant ${kind}`);
  console.log(`\n${label}: paired as ${c.client}`);
  const calls = [
    ["clients/list", {}, null],
    ["clients/startPairing", {}, null],
    ["hosts/startEnroll", {}, null],
    ["clients/stopPairing", {}, null],
    ["projects/setHelperLimits", { folder: `file://${folder}`, limits: { running: 4, notArchived: 6 } }, "mac"],
    ["files/browse", { path: folder.replace(/\/[^/]+\/?$/, "") }, "mac"],
    ["clientPermissions/state", {}, "mac"],
    ["projects/list", {}, "mac"],
  ];
  for (const [method, params, host] of calls) {
    const answer = await c.ask(method, params, host);
    if (answer.error?.code === -32045) refused += 1;
    console.log(`  ${(host ? host + " " : "control ") + method}: ${brief(answer)}`);
  }
  c.close();
}
console.log(`\nrefused by grant: ${refused}`);
process.exit(refused === 0 ? 0 : 1);

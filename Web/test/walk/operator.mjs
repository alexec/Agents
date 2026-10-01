// A stand-in for the window's Settings ▸ Control plane ▸ Clients, for walks where the window
// can't be pressed (no Accessibility permission): an operator client over the control plane's
// TLS address, speaking the same wire with the web remote's own code, as kind "mac". It makes
// the calls Settings makes: clients/startPairing, clients/list, clients/setGrant,
// clients/forget. Walks only; never pointed at the real control plane.
//
//   const op = await Operator.pair(controlURL, operatorCode);
//   const code = await op.call("clients/startPairing", { grant: "device" });

import { load } from "../load.mjs";

process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0"; // the scratch copy's self-signed certificate
const w = await load("test/wire.ts");

export class Operator {
  static async pair(controlURL, codeText) {
    const origin = new URL(controlURL).origin;
    const url = controlURL.replace(/^http/, "ws") + "/v1/connect";
    const code = w.parseCode(codeText);
    if (!code) throw new Error("not a client code");
    const keys = new w.MemoryKeyStore();
    const socket = await opened(url);
    const lines = linesOf(socket);
    await w.pair(lines, code, origin, "walk operator", async () => {
      const { pair, publicRaw } = await w.makeKeyPair();
      const client = w.newClientID();
      keys.record = { privateKey: pair.privateKey, publicKey: pair.publicKey, client,
        control: w.base64url(code.controlKey), grant: code.grant, paired: "" };
      return { client, publicRaw };
    }, undefined, "mac");
    socket.close();
    const link = new w.Link({ url, origin, keys, open: (u) => new WebSocket(u), heartbeat: { every: 60_000, within: 5_000 },
      authenticate: (s, record, o) => w.connect(s, record, o, undefined, "mac") });
    await new Promise((resolve, reject) => {
      const stop = link.onState((state) => {
        if (state.kind === "open") { stop(); resolve(); }
        if (["forgotten", "unsupported", "wrongControlPlane", "unpaired"].includes(state.kind)) reject(new Error(state.kind));
      });
      link.start();
    });
    return new Operator(link);
  }

  constructor(link) { this.link = link; }
  call(method, params = {}) { return this.link.call(method, params); }
  stop() { this.link.stop(); }
}

function opened(url) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url);
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

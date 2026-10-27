// The person's Mac on the page (#1501): with a control plane elsewhere, this Mac's host joins with
// an id of its own, not `mac`. The page takes the control plane's home host, when it is a Mac, as
// "This Mac": it keeps the display choices there and names it so.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { Store } = await load("test/tokenAsk.ts");
const { workflowHostChoices } = await load("src/model/workflows.ts");
const { folderLabel, orderedFolders } = await load("src/views/Sidebar.tsx");
const { offlineStrip } = await load("src/views/OfflineStrip.tsx");

const mac = { id: "wd2lxg5e", name: "Studio", platform: "macOS 26.1", version: "0.5.0", state: "online", reach: "uplink", machineID: "M1" };
const server = { id: "box", name: "box", platform: "Linux 6.8", version: "0.5.0", state: "online", reach: "uplink", machineID: "M2" };

/** A link to a control plane with `hosts` and the home host `home`, that keeps what it was asked. */
function planeLink(hosts, home) {
  const asked = [];
  return {
    asked,
    onNotification: () => {},
    onState: () => {},
    call: async (method, params, host) => {
      asked.push({ method, host });
      if (method === "machines/list") return hosts;
      if (method === "control/status") return { name: "Plane", version: "0.5.0", machineID: "P", ...(home ? { homeHost: home } : {}) };
      if (method === "machines/listKept") return { kept: [] };
      throw new Error("no");
    },
  };
}

test("with no host mac, the home host that is a Mac is this Mac, and its display choices are read from it", async () => {
  const link = planeLink([server, mac], mac.id);
  const store = new Store(link);
  await store.load();
  assert.equal(store.macHostID.value, mac.id);
  assert.equal(store.isMac(mac.id), true);
  assert.equal(store.isMac("box"), false);
  assert.equal(store.recipient(mac.id), "your Mac");
  assert.equal(store.recipient("box"), "box");
  assert.deepEqual(link.asked.filter((c) => c.method === "preferences/get").map((c) => c.host), [mac.id]);
});

test("a host mac is this Mac, whatever the home host", async () => {
  const link = planeLink([{ ...mac, id: "mac" }, server], "box");
  const store = new Store(link);
  await store.load();
  assert.equal(store.macHostID.value, "mac");
});

test("a home host that is not a Mac is not called This Mac", async () => {
  const link = planeLink([server, mac], "box");
  const store = new Store(link);
  await store.load();
  assert.equal(store.macHostID.value, "mac");
  assert.equal(store.isMac("box"), false);
  assert.deepEqual(link.asked.filter((c) => c.method === "preferences/get"), []);
});

test("the sidebar, the workflow host menu and the offline strip name the person's Mac by its id", () => {
  const folder = { name: "Agents", folder: { folder: "file:///u/Agents/", addedAt: 1 } };
  assert.equal(folderLabel(mac, folder, mac.id), "Agents");
  assert.equal(folderLabel(server, folder, mac.id), "box:Agents");
  assert.equal(folderLabel(mac, folder), "Studio:Agents", "without the id, only a host mac is this Mac");
  assert.deepEqual(orderedFolders([server, mac], { box: [folder], [mac.id]: [folder] }, mac.id).map((r) => r.host.id), [mac.id, "box"]);
  assert.deepEqual(workflowHostChoices([server, mac], mac.id).map((c) => c.name), ["This Mac", "box"]);
  assert.match(offlineStrip(mac.id, { ...mac, state: "offline" }, null, mac.id).line, /^This Mac hasn’t answered/);
  assert.match(offlineStrip("box", { ...server, state: "offline" }, null, mac.id).line, /^box is offline/);
});

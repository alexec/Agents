// Machine providers on the web (#1808): the API kinds' requests, with their secrets only in
// `secrets`; an edit that keeps what it leaves out; the card's lines; Link to Host's choices; and
// the model against a fake control plane, Stop's question included.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const w = await load("test/machineProviders.ts");

test("only the API kinds are offered, with the window's titles", () => {
  assert.deepEqual([...w.providerKinds], ["digitalOcean", "codespaces", "coder", "aws", "compute"]);
  assert.equal(w.kindTitle("digitalOcean"), "DigitalOcean Droplets");
  assert.equal(w.kindOfPreset("digitalocean-api"), "digitalOcean");
  assert.equal(w.kindOfPreset("doctl"), undefined);
});

test("DigitalOcean: the token goes only in secrets, tag and user default", () => {
  const r = w.providerRequest("digitalOcean", "", { token: " dop_v1_x " });
  assert.deepEqual(r, { name: "DigitalOcean Droplets", kind: "commands",
    commands: { preset: "digitalocean-api", tag: "agents", user: "root" }, secrets: { DIGITALOCEAN_API_TOKEN: "dop_v1_x" } });
  assert.ok(!JSON.stringify(r.commands).includes("dop_v1_x"));
});

test("each kind says what is missing", () => {
  assert.equal(w.providerRequest("digitalOcean", "DO", {}), "Give the API token.");
  assert.equal(w.providerRequest("coder", "C", { token: "t" }), "Give the deployment’s address.");
  assert.equal(w.providerRequest("aws", "A", { accessKey: "k", secretKey: "s" }), "Give the region.");
  assert.equal(w.providerRequest("compute", "G", { serviceKey: "{}" }), "Give the project and the zone.");
});

test("AWS, Compute, Codespaces and Coder build their presets", () => {
  assert.deepEqual(w.providerRequest("aws", "A", { accessKey: "AK", secretKey: " s ", region: "eu-west-1" }), {
    name: "A", kind: "commands", commands: { preset: "aws-ec2-api", region: "eu-west-1", tag: "agents", user: "ec2-user" },
    secrets: { AWS_ACCESS_KEY_ID: "AK", AWS_SECRET_ACCESS_KEY: " s " } });
  assert.deepEqual(w.providerRequest("compute", "G", { serviceKey: "{}", project: "p", zone: "z", sshKey: "ssh-ed25519 K" }).commands,
    { preset: "gcp-compute-api", project: "p", zone: "z", label: "agents", user: "agents", sshKeys: ["ssh-ed25519 K"] });
  assert.deepEqual(w.providerRequest("codespaces", "", { token: "ghp", repo: "o/r" }).commands, { preset: "codespaces-api", repo: "o/r" });
  assert.deepEqual(w.providerRequest("coder", "", { token: "t", url: "https://c" }).commands, { preset: "coder-api", url: "https://c" });
});

test("an edit sends the name and only the secrets given, so the control plane keeps the rest", () => {
  const editing = { id: "do", name: "DO", preset: "digitalocean-api" };
  assert.deepEqual(w.providerRequest("digitalOcean", "Droplets", {}, editing), { id: "do", name: "Droplets", kind: "commands", secrets: {} });
  assert.deepEqual(w.providerRequest("digitalOcean", "DO", { token: "new" }, editing).secrets, { DIGITALOCEAN_API_TOKEN: "new" });
});

const summary = (over = {}) => ({ id: "do", name: "DO", kind: "commands", secrets: {}, capabilities: [], contract: 1,
  mapped: false, workspaces: [], current: true, ...over });

test("the card's chip and lines are the window's", () => {
  assert.equal(w.kindChip(summary({ preset: "digitalocean-api" })), "command provider · digitalocean-api · API");
  assert.equal(w.kindChip(summary({ preset: "doctl" })), "command provider · doctl · CLI");
  assert.equal(w.providerLine(summary({ preset: "codespaces-api", listedAt: 0, sshToolMissing: "gh" }), () => "9:00"), "Listed 9:00 · No machines · needs gh for ssh");
  // The control plane has gh (#3367): nothing to say.
  assert.equal(w.providerLine(summary({ preset: "codespaces-api", listedAt: 0 }), () => "9:00"), "Listed 9:00 · No machines");
  assert.equal(w.providerLine(summary({ problem: "401", current: false }), () => ""), "Couldn’t list: 401");
  const hosts = [{ id: "h1", name: "box" }];
  assert.equal(w.workspaceLine({ id: "a", name: "a", state: "running", host: "h1", cost: "$4/mo" }, hosts), "Running · linked to box · $4/mo");
  assert.equal(w.workspaceLine({ id: "a", name: "a", state: "stopped" }, hosts), "Stopped · not joined");
});

test("Link to Host offers free hosts that run agents, the likely one first", () => {
  const hosts = [
    { id: "1", name: "other" }, { id: "2", name: "cws.devbox" }, { id: "3", name: "relay", relay: true },
    { id: "4", name: "devbox", workspace: { provider: "p" } },
  ];
  assert.deepEqual(w.linkableHosts({ id: "x", name: "devbox", state: "running" }, hosts).map((h) => h.id), ["2", "1"]);
  assert.deepEqual(w.linkableHosts({ id: "x", name: "devbox", state: "running", host: "4" }, hosts), []);
});

test("a workspace no host can be linked to says where to make it one (#1931)", () => {
  const taken = [{ id: "4", name: "devbox", workspace: { provider: "p" } }, { id: "3", name: "relay", relay: true }];
  assert.equal(w.noHostLine({ id: "x", name: "other", state: "stopped" }, taken), w.providerWords.notAHostYet);
  assert.equal(w.noHostLine({ id: "x", name: "other", state: "running" }, [...taken, { id: "1", name: "free" }]), undefined);
  assert.equal(w.noHostLine({ id: "x", name: "devbox", state: "running", host: "4" }, taken), undefined);
  // One with an ssh destination has Add as Machine… in place of the line (#3365).
  assert.equal(w.noHostLine({ id: "x", name: "other", state: "stopped", ssh: "cs.other" }, taken), undefined);
});

test("Add as Machine… is offered with an ssh destination, and pressable only while it runs (#3365)", () => {
  assert.deepEqual(w.addAsMachine({ id: "x", name: "cs", state: "running", ssh: "cs.cs" }), { ready: true, help: w.providerWords.addAsMachineHelp });
  assert.deepEqual(w.addAsMachine({ id: "x", name: "cs", state: "stopped", ssh: "cs.cs" }), { ready: false, help: w.providerWords.startFirst });
  assert.equal(w.addAsMachine({ id: "x", name: "cs", state: "running" }), undefined);
  assert.equal(w.addAsMachine({ id: "x", name: "cs", state: "running", ssh: "cs.cs", host: "4" }), undefined);
});

test("a provider's ssh with a port is one word, as ssh takes it", () => {
  assert.equal(w.sshDestination("alex@127.0.0.1 -p 2222"), "ssh://alex@127.0.0.1:2222");
  assert.equal(w.sshDestination(" cs.devbox "), "cs.devbox");
  assert.equal(w.sshDestination("a@b -p x"), "a@b -p x");
});

test("Add as Machine… installs, shows a new host key first, and links the machine once it joins (#3365)", async () => {
  const asked = [];
  const p = new w.Providers({
    call: async (method, params) => {
      asked.push({ method, params });
      if (method === "hosts/install") return params.trust ? { name: "cs-box", tunnel: false } : { needsTrust: "SHA256:abc", name: "cs-box" };
      if (method === "hosts/link") return {};
      throw new Error(method);
    },
  });
  assert.deepEqual(await p.install("cs.cs-box", "cs-box", "gh", "cs-box-id"), { needsTrust: "SHA256:abc" });
  assert.deepEqual(await p.install("cs.cs-box", "cs-box", "gh", "cs-box-id", "SHA256:abc"), { added: "cs-box" });
  assert.deepEqual(asked.at(-1).params, { destination: "cs.cs-box", name: "cs-box", trust: "SHA256:abc" });
  // Not joined yet: nothing to link.
  p.linkJoined([{ id: "1", name: "other" }]);
  assert.equal(asked.filter((a) => a.method === "hosts/link").length, 0);
  p.linkJoined([{ id: "1", name: "other" }, { id: "7", name: "cs-box" }]);
  p.linkJoined([{ id: "7", name: "cs-box" }]);
  // The key trusted for the install is the one the link keeps (#3379).
  assert.deepEqual(asked.filter((a) => a.method === "hosts/link").map((a) => a.params),
    [{ host: "7", provider: "gh", workspace: "cs-box-id", trust: "SHA256:abc" }]);
});

test("Link to Machine… shows a new host key first, then links with it trusted (#3379)", async () => {
  assert.ok(w.callTimeoutFor("hosts/link") >= 60_000);
  const asked = [];
  const p = new w.Providers({
    call: async (method, params) => {
      asked.push(params);
      if (params.trust === "SHA256:abc") return {};
      throw new w.CallFailed(w.Failure.hostKeyToTrust, "This machine’s host key is new.", { fingerprint: "SHA256:abc" });
    },
  });
  assert.deepEqual(await p.link("7", "gh", "cs", true, 30), { needsTrust: "SHA256:abc" });
  assert.deepEqual(await p.link("7", "gh", "cs", true, 30, "SHA256:abc"), { linked: true });
  assert.deepEqual(asked.at(-1), { host: "7", provider: "gh", workspace: "cs", startWhenUsed: true, stopWhenIdleMinutes: 30, trust: "SHA256:abc" });
  const refused = new w.Providers({ call: async () => { throw new w.CallFailed(-32602, "There is no such workspace."); } });
  assert.deepEqual(await refused.link("7", "gh", "cs", true, 30), { failed: "There is no such workspace." });
});

test("Add as Machine… says why the control plane refused", async () => {
  const p = new w.Providers({ call: async () => { throw new w.CallFailed(-32001, "Only the control plane's owner can use its ssh."); } });
  assert.deepEqual(await p.install("cs.x", "x", "gh", "x"), { failed: "Only the control plane's owner can use its ssh." });
});

test("Add as Machine… waits for the install, and links the machine also when the page stopped waiting (#3377)", async () => {
  assert.ok(w.callTimeoutFor("hosts/install") >= 10 * 60_000);
  const linked = [];
  const p = new w.Providers({
    call: async (method, params) => {
      if (method === "hosts/install") throw new w.CallTimedOut("hosts/install");
      if (method === "hosts/link") return linked.push(params);
      throw new Error(method);
    },
  });
  assert.ok("failed" in await p.install("cs.cs-box", "cs-box", "gh", "cs-box-id"));
  p.linkJoined([{ id: "7", name: "cs-box" }]);
  assert.deepEqual(linked, [{ host: "7", provider: "gh", workspace: "cs-box-id" }]);
  // A refusal installed nothing: nothing to link.
  const refused = new w.Providers({
    call: async (method, params) => {
      if (method === "hosts/install") throw new w.CallFailed(-32001, "No.");
      return linked.push(params);
    },
  });
  await refused.install("cs.x", "x", "gh", "x");
  refused.linkJoined([{ id: "8", name: "x" }]);
  assert.equal(linked.length, 1);
});

function plane({ oneCopy = true, working = false } = {}) {
  const asked = [];
  return {
    asked,
    call: async (method, params) => {
      asked.push({ method, params });
      if (method === "providers/list") {
        if (!oneCopy) throw new w.CallFailed(w.Failure.providersNeedOneCopy, "Machine providers are off on this control plane, because it has no folder for their secrets.");
        return { providers: [summary()] };
      }
      if (method === "providers/refresh") return {};
      if (method === "providers/add") return summary({ id: "new", name: params.name });
      if (method === "providers/remove") return {};
      if (method === "hosts/stop") {
        if (working && !params.confirmRunning) throw new w.CallFailed(w.Failure.agentsWorking, "Stop box? A is working there.");
        return { id: params.host };
      }
      throw new Error(method);
    },
  };
}

test("the model lists, asks for a fresh list, adds, removes, and takes the notice", async () => {
  const link = plane();
  const p = new w.Providers(link);
  await p.load();
  // The groups too, for each provider's group (#1761).
  assert.deepEqual(link.asked.map((a) => a.method), ["providers/list", "groups/list", "providers/refresh"]);
  assert.deepEqual(p.list.value.map((x) => x.id), ["do"]);
  assert.equal(await p.save({ name: "N", kind: "commands", secrets: { T: "s" } }), null);
  assert.deepEqual(p.list.value.map((x) => x.id), ["do", "new"]);
  assert.equal(await p.remove("do"), null);
  assert.deepEqual(p.list.value.map((x) => x.id), ["new"]);
  p.take({ providers: [summary({ id: "z" })] });
  assert.deepEqual(p.list.value.map((x) => x.id), ["z"]);
  // Nothing the page holds carries a secret's value.
  assert.ok(!JSON.stringify(p.list.value).includes("\"s\""));
});

test("a control plane that runs no providers says why, in its own words (#3113)", async () => {
  const p = new w.Providers(plane({ oneCopy: false }));
  await p.load();
  assert.equal(p.off.value, "Machine providers are off on this control plane, because it has no folder for their secrets.");
  assert.equal(p.problem.value, null);
});

test("Stop asks first while agents work there, then stops with confirmRunning", async () => {
  const link = plane({ working: true });
  const p = new w.Providers(link);
  assert.deepEqual(await p.stop("h1"), { host: "h1", question: "Stop box? A is working there." });
  assert.equal(await p.stop("h1", true), null);
  assert.deepEqual(link.asked.at(-1).params, { host: "h1", confirmRunning: true });
});

test("Link to Machine with no machine says Add a Machine…, not the Mac app (#3382)", () => {
  assert.doesNotMatch(w.providerWords.noHosts, /\bMac\b/);
  assert.match(w.providerWords.noHosts, /Add a Machine…/);
});

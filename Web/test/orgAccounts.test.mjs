// The organisation's ways to the model (#999): its words, as OrgAccountWordsTests checks them in Swift, and
// Console ▸ Model Access's route form.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const a = await load("src/model/orgAccounts.ts");

test("each kind has its name, and a member's line says name, kind and runtimes only", () => {
  assert.deepEqual(a.kinds.map(a.kindName), ["Org key", "Amazon Bedrock", "Google Vertex AI", "Microsoft Azure", "Gateway"]);
  assert.equal(a.mineLine({ id: "acme", name: "Acme Bedrock", kind: "bedrock", runtimes: ["claude", "opencode"], defaultFor: ["claude"] }),
    "Amazon Bedrock · Claude, OpenCode · default for Claude");
});

test("a reach rule says the ways allowed", () => {
  assert.equal(a.reachWords(["gateway", "orgKey"]), "Org key or gateway only");
  assert.equal(a.reachWords(["signIn"]), "Own sign-in only");
  assert.equal(a.reachWords(["orgKey"]), "Org key only");
  assert.equal(a.reachWords(["signIn", "orgKey", "gateway"]), "Any way");
  assert.equal(a.reachChoiceOf(undefined), "any");
  assert.equal(a.reachChoiceOf(["signIn"]), "signIn");
  assert.equal(a.reachChoiceOf(["orgKey", "gateway"]), "org");
});

test("the refusals name the runtime and the route", () => {
  assert.equal(a.requires("claude", "Acme Bedrock"), "Your organisation requires Claude to use Acme Bedrock.");
  assert.equal(a.routeRemoved("Acme Bedrock"), "Your organisation removed Acme Bedrock.");
});

test("each kind serves only the runtimes the relay can carry, by the API they speak", () => {
  assert.deepEqual(a.runtimesFor("bedrock", undefined), ["claude", "opencode"]);
  assert.deepEqual(a.runtimesFor("key", "openai"), ["codex", "opencode"]);
  assert.deepEqual(a.runtimesFor("vertex", undefined), ["claude", "opencode"]);
  assert.deepEqual(a.runtimesFor("key", undefined), []);
  assert.deepEqual(a.vendorsFor("azure").sort(), ["anthropic", "openai"]);
  assert.deepEqual(a.vendorsFor("bedrock"), []);
});

test("a new route is made from the form, with its secrets apart and no id", () => {
  const form = a.newRouteForm();
  form.name = " Acme Bedrock ";
  form.kind = "bedrock";
  form.vendor = "";
  form.runtimes = ["claude", "codex"];
  form.settings = { region: "us-east-1", address: "https://ignored" };
  form.secrets = { apiKey: "  sk-1  ", entraClientSecret: "not this kind's" };
  form.models = "claude-sonnet-4-5 = us.anthropic.claude-sonnet-4-5-v1:0";
  form.defaultFor = ["claude", "codex"];
  const made = a.routeOf(form, undefined);
  assert.deepEqual(made.route, { id: "", name: "Acme Bedrock", kind: "bedrock", runtimes: ["claude"], settings: { region: "us-east-1" },
    models: { "claude-sonnet-4-5": "us.anthropic.claude-sonnet-4-5-v1:0" }, groups: [], defaultFor: ["claude"] });
  assert.deepEqual(made.secrets, { apiKey: "sk-1" });
});

test("an edit keeps the route's id and what the form does not show, and an empty secret keeps its value", () => {
  const base = { id: "acme", name: "Acme", kind: "key", vendor: "anthropic", runtimes: ["claude"], secretFields: ["apiKey"],
    fingerprint: { apiKey: "1a2b3c4d" }, version: 2, machines: 3, groups: ["g1"], defaultFor: [] };
  const form = a.routeFormOf(base);
  assert.equal(form.vendor, "anthropic");
  const made = a.routeOf(form, base);
  assert.equal(made.route.id, "acme");
  assert.equal(made.route.machines, undefined);
  assert.deepEqual(made.route.fingerprint, { apiKey: "1a2b3c4d" });
  assert.deepEqual(made.route.groups, ["g1"]);
  assert.deepEqual(made.secrets, {});
});

test("a form that cannot be a route says why", () => {
  const form = a.newRouteForm();
  assert.match(a.routeOf(form, undefined).problem, /^Give the route a name/);
  form.name = "Acme";
  form.vendor = "";
  assert.equal(a.routeOf(form, undefined).problem, "Say whose API the route speaks.");
  form.vendor = "anthropic";
  form.runtimes = ["codex"];
  assert.equal(a.routeOf(form, undefined).problem, "Choose the runtimes it is for: Org key can serve Claude, OpenCode.");
  form.runtimes = ["claude"];
  form.models = "just-one";
  assert.match(a.routeOf(form, undefined).problem, /^“just-one” is not a model/);
});

test("an admin reads the fingerprints, who may use it and how many machines hold it", () => {
  const r = { id: "x", name: "X", kind: "bedrock", runtimes: ["claude"], fingerprint: { awsAccessKeyId: "aa", awsSecretAccessKey: "bb" }, machines: 1 };
  assert.equal(a.fingerprintWords(r), "AWS access key aa · AWS secret bb");
  assert.equal(a.fingerprintWords({ ...r, fingerprint: undefined }), "No key");
  assert.equal(a.whoWords(r, () => undefined), "Everyone");
  assert.equal(a.whoWords({ ...r, groups: ["g1", "g2"] }, (id) => (id === "g1" ? "Platform" : undefined)), "Platform, g2");
  assert.equal(a.heldWords(r), "Held by 1 machine");
  assert.equal(a.heldWords({ ...r, machines: 0 }), "Held by no machine");
});

// agents://agent/<id> links select their session on the web page, as on the Mac and the Remote (#3353).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

globalThis.location = { hash: "" };
const { agentLinkID, startAgentLinks, renderMarkdown } = await load("test/agentLink-entry.ts");

const id = "6f1c2a9e-3b4d-4e5f-8a7b-9c0d1e2f3a4b";
const agent = { id, cwd: "file:///Users/a/Project/", worktree: undefined };

/** The first button among the nodes, at any depth. */
function button(nodes) {
  for (const node of [nodes].flat(Infinity)) {
    if (!node || typeof node !== "object") continue;
    if (node.type === "button") return node;
    const inner = button(node.props.children);
    if (inner) return inner;
  }
  return undefined;
}

function fakeStore({ held = {}, asked = {} } = {}) {
  const calls = [];
  return {
    calls,
    agents: { value: held },
    hosts: { value: Object.keys(asked).map((host) => ({ id: host })) },
    loadEventAgent: async (host, agentID) => { calls.push([host, agentID]); return asked[host]?.id === agentID ? asked[host] : undefined; },
  };
}

test("only an agents://agent/<id> link names a session", () => {
  assert.equal(agentLinkID(`agents://agent/${id}`), id);
  assert.equal(agentLinkID(`agents://agent/${id.toUpperCase()}`), id.toUpperCase());
  assert.equal(agentLinkID("agents://agent/not-an-id"), null);
  assert.equal(agentLinkID(`agents://docs/${id}`), null);
  assert.equal(agentLinkID(`https://example.com/agent/${id}`), null);
});

test("a link to a session is a button, never an address", () => {
  const link = button(renderMarkdown(`- [Fix the build](agents://agent/${id}) finished`));
  assert.ok(link);
  assert.equal(link.props.href, undefined);
  assert.equal(link.props.children, "Fix the build");
});

test("a click selects the session the page holds, whatever the id's case", async () => {
  startAgentLinks(fakeStore({ held: { mac: [agent] } }));
  location.hash = "";
  button(renderMarkdown(`[s](agents://agent/${id.toUpperCase()})`)).props.onClick();
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(location.hash, `#/h/mac/p/${encodeURIComponent("file:///Users/a/Project")}/s/${id}`);
});

test("a session the page does not hold is asked of each host, archived too", async () => {
  const store = fakeStore({ asked: { linux: agent } });
  startAgentLinks(store);
  location.hash = "";
  button(renderMarkdown(`[s](agents://agent/${id})`)).props.onClick();
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(store.calls, [["linux", id]]);
  assert.equal(location.hash, `#/h/linux/p/${encodeURIComponent("file:///Users/a/Project")}/s/${id}`);
});

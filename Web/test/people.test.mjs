// Settings ▸ People's words and a machine's ask to join (#994), as the window and the Remote have them.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const p = await load("src/model/people.ts");

const person = (over = {}) => ({ id: "u", name: "Sam", kind: "person", role: "member", signIns: [], clients: [], machines: [], ...over });
const request = (over = {}) => ({ request: "r1", name: "box-1", platform: "Linux", code: "4821", expires: 782654400, for: "me", ...over });

test("a person's marks, role, machines and clients", () => {
  assert.deepEqual(p.badges(person({ you: true, localOwner: true })), ["You", "Local owner"]);
  assert.deepEqual(p.badges(person()), []);
  assert.equal(p.roleWord("admin"), "Admin");
  assert.equal(p.roleWord("member"), "Member");
  assert.equal(p.machineLine({ id: "h", name: "box-1", state: "online", platform: "Linux" }), "box-1 · Online · Linux");
  assert.equal(p.machineLine({ id: "h", name: "box-2", state: "notJoined" }), "box-2 · Not joined");
  assert.equal(p.clientLine({ id: "c", name: "MacBook Pro", kind: "mac" }), "MacBook Pro · Mac window");
  assert.equal(p.clientLine({ id: "c", name: "", kind: "iPhone" }), "iPhone");
});

test("you first, then the local owner, then by name", () => {
  const got = p.ordered([person({ id: "b", name: "Zoe" }), person({ id: "o", name: "Owner", localOwner: true }),
    person({ id: "a", name: "Al" }), person({ id: "y", name: "Me", you: true })]);
  assert.deepEqual(got.map((x) => x.id), ["y", "o", "a", "b"]);
});

test("an admin changes roles but never leaves no admin, and removes neither themselves nor the local owner", () => {
  const owner = person({ id: "o", role: "admin", localOwner: true, you: true });
  const sam = person({ id: "s" });
  assert.equal(p.canSetRole(owner, [owner, sam], true), false);
  assert.equal(p.canSetRole(sam, [owner, sam], true), true);
  assert.equal(p.canSetRole(sam, [owner, sam], false), false);
  assert.equal(p.canSetRole(owner, [owner, person({ id: "t", role: "admin" })], true), true);
  assert.equal(p.canRemove(owner, true), false);
  assert.equal(p.canRemove(sam, true), true);
  assert.equal(p.canRemove(sam, false), false);
});

test("Remove says what goes", () => {
  assert.deepEqual(p.removeLines(person({
    clients: [{ id: "c1", name: "Sam's iPhone", kind: "iPhone" }, { id: "c2", name: "", kind: "browser" }],
    machines: [{ id: "h", name: "box-1", state: "online" }],
  })), ["2 clients can no longer connect: Sam's iPhone, Web page.", "1 machine is taken off: box-1."]);
  assert.deepEqual(p.removeLines(person()), ["Sam has no clients or machines."]);
  assert.equal(p.removeTitle("Sam"), "Remove Sam?");
});

test("Remove says which machines are deleted and the work on them that is not pushed (#1763)", () => {
  const preview = {
    startedMachines: [
      { host: "w", name: "sam-ws", state: "online", unpushed: [
        { folder: "file:///p", worktree: "file:///p-fix", branch: "agents/fix", ahead: 2, uncommitted: 3 },
        { folder: "file:///p", worktree: "file:///p-new/", unmerged: 1 },
      ] },
      { host: "x", name: "sam-old", state: "offline", unpushed: [], unknown: "sam-old is not online, so it could not be asked." },
    ],
    registeredMachines: [{ id: "h", name: "box-1", state: "online" }],
  };
  assert.deepEqual(p.removeLines(person({ machines: [{ id: "h", name: "box-1", state: "online" }] }), preview), [
    "2 machines are stopped and deleted: sam-ws, sam-old.",
    "On sam-ws, this work is not pushed and is lost: agents/fix (2 commits not pushed, changes not committed); p-new (1 commit never pushed).",
    "sam-old is not online, so it could not be asked.",
    "1 machine is taken off: box-1.",
  ]);
  assert.equal(p.askingLine("Sam"), "Asking Sam’s machines what work on them is not pushed…");
  assert.equal(p.checkFailedLine("Sam", "The control plane can’t be reached."),
    "Could not check what Sam’s machines would lose. The control plane can’t be reached. Removing Sam stops and "
    + "deletes the machines Sam started, with any work on them not pushed, so Remove stays off until the check works.");
});

test("an invite says how long it works and where it goes", () => {
  const note = p.inviteNote({ name: "Sam", expires: 782654400 }, "en-US");
  assert.match(note, /^Works once, until [A-Z][a-z]+day, October \d+\. Send it to Sam; they paste it where a code is asked for in the Mac window or the Remote\.$/);
});

test("a machine's ask names its person", () => {
  assert.equal(p.joinWords(request(), "me"), "wants to join as you");
  assert.equal(p.joinWords(request({ for: "u2", forName: "Sam" }), "me"), "wants to join as Sam");
  assert.equal(p.joinWords(request({ for: "u2" }), "me"), "wants to join as u2");
  assert.equal(p.joinWords(request({ for: "" }), "me"), "wants to join. It names no person.");
  assert.equal(p.codeLine("4821"), "Check that the machine shows 4821");
});

test("asks are added, said again, decided and expired", () => {
  let list = p.withJoin([], request());
  list = p.withJoin(list, request({ request: "r2", name: "box-2" }));
  list = p.withJoin(list, request({ name: "box-1b" }));
  assert.deepEqual(list.map((r) => [r.request, r.name]), [["r1", "box-1b"], ["r2", "box-2"]]);
  assert.deepEqual(p.withoutJoin(list, "r1").map((r) => r.request), ["r2"]);
  const at = new Date(Date.UTC(2001, 0, 1) + 782654400 * 1000);
  const live = p.liveJoins([request({ expires: 782654400 - 1 }), request({ request: "r2", expires: 782654400 + 60 })], at);
  assert.deepEqual(live.map((r) => r.request), ["r2"]);
});

test("a machine joins without a code by a command", () => {
  assert.equal(p.joinCommandTitle, "Add a machine without a code");
  assert.equal(p.joinCommandNote, "Run it on the machine. It shows a code; approve it here.");
});

test("what an org provider controls is said under a person, with its name (#1002, FR-028)", () => {
  const names = { okta: "Okta" };
  const scim = { provider: "okta", userName: "sam@example.com", active: true };
  assert.deepEqual(p.orgLines(person({ scim }), names), ["Managed by Okta"]);
  assert.deepEqual(p.orgLines(person({ scim, provisioned: true }), names), ["Managed by Okta", "Waiting for first sign-in"]);
  assert.deepEqual(p.orgLines(person({ suspended: { by: "scim", provider: "entra", at: 0 } }), names), ["Suspended by entra"]);
  assert.deepEqual(p.orgLines(person(), names), []);
  assert.equal(p.providerManaged(person()), false);
  assert.equal(p.providerManaged(person({ roleFrom: ["g1"] })), true);
});

test("a role a provider's group gives says Set by, and the menu does not change it", () => {
  const names = { okta: "Okta" };
  const groups = [{ id: "g1", name: "Admins", everyone: false, members: [], source: { scim: "okta", displayName: "Admins" }, role: "admin" }];
  const admin = person({ id: "a", role: "admin", roleFrom: ["g1"] });
  const other = person({ id: "b", role: "admin" });
  assert.equal(p.roleSetBy(admin, groups, names), "Set by Okta");
  assert.equal(p.roleSetBy(person({ roleFrom: ["gone"], scim: { provider: "okta", userName: "x", active: true } }), [], names), "Set by Okta");
  assert.equal(p.roleSetBy(other, groups, names), null);
  assert.equal(p.canSetRole(admin, [admin, other], true), false);
  assert.equal(p.canSetRole(other, [admin, other], true), true);
});

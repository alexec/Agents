// Add a Machine… (#2131): the machine name it takes, Where agents run's line, and New Machine's
// request with no repository.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const a = await load("src/model/addMachine.ts");
const m = await load("src/model/machineFromRepository.ts");

test("a machine name is letters, digits and dashes, starting with a letter", () => {
  assert.equal(a.validMachineName("build-2"), true);
  assert.equal(a.validMachineName(" devbox "), true);
  assert.equal(a.validMachineName("2-build"), false);
  assert.equal(a.validMachineName("build 2"), false);
  assert.equal(a.validMachineName(""), false);
  assert.equal(a.validMachineName("b".repeat(64)), false);
});

test("Where agents run says where the folder is, and what else is yours", () => {
  assert.equal(a.whereAgentsRun.line([], []), "Agents run where this folder is.");
  assert.equal(a.whereAgentsRun.line(["devbox", "build-2"], ["Docker"]),
    "Agents run where this folder is. Your other machines: devbox, build-2. Providers: Docker.");
  assert.equal(a.whereAgentsRun.title(true, "alex-mbp"), "This Mac");
  assert.equal(a.whereAgentsRun.title(false, "devbox"), "devbox");
});

test("New Machine with no repository sends none", () => {
  const request = m.createRequest("p1", "build-2", null, [{ key: "size", title: "Size", kind: "string", value: "s-1vcpu" }]);
  assert.deepEqual(request, { id: "p1", name: "build-2", options: { size: "s-1vcpu" } });
  const withRepo = m.createRequest("p1", "api-1a2b", m.repositoryOf("https://github.com/you/api"), []);
  assert.equal(withRepo.repository, "https://github.com/you/api");
});

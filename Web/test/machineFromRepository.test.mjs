// Start a Machine from a Repository (#1809): what an https repository is, the machine's name,
// the providers that make machines, the provider's form without `repository`, and the request.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const m = await load("src/model/machineFromRepository.ts");

test("a repository is an https address with an owner and a name", () => {
  assert.deepEqual(m.repositoryOf(" https://github.com/alexec/agents.git "),
    { url: "https://github.com/alexec/agents.git", path: "alexec/agents", name: "agents" });
  assert.equal(m.repositoryOf("https://gitlab.com/group/sub/proj").path, "group/sub/proj");
  for (const bad of ["git@github.com:alexec/agents.git", "http://github.com/a/b", "https://github.com/agents",
    "https://token@github.com/a/b", "https://github.com/a/b?x=1", ""]) {
    assert.equal(m.repositoryOf(bad), null, bad);
  }
});

test("the machine's name is the repository's, as a host name, with a suffix", () => {
  assert.equal(m.machineName("Agents", "0a1f"), "agents-0a1f");
  assert.equal(m.machineName("my_repo.js", "beef"), "my-repo-js-beef");
  assert.equal(m.machineName("2048", "0001"), "m-2048-0001");
  assert.equal(m.machineName("a".repeat(40), "0001"), `${"a".repeat(30)}-0001`);
  assert.match(m.machineName("x", m.nameSuffix(() => 0.5)), /^x-8000$/);
});

test("only providers that make machines are offered", () => {
  const p = (id, capabilities) => ({ id, name: id, capabilities });
  assert.deepEqual(m.makers([p("do", ["create", "delete"]), p("coder", [])]).map((x) => x.id), ["do"]);
});

test("the form leaves out repository, and the request types its values", () => {
  const fields = m.formFields({ type: "object", properties: {
    repository: { type: "string" },
    region: { type: "string", title: "Region", default: "nyc3", description: "A slug." },
    size: { type: "string", enum: ["small", "big"], default: "small" },
    disk: { type: "integer", title: "Disk", default: 20 },
    spot: { type: "boolean", default: false },
  } });
  assert.deepEqual(fields.map((f) => [f.key, f.kind, f.value]), [["region", "string", "nyc3"], ["size", "string", "small"],
    ["disk", "integer", "20"], ["spot", "boolean", "false"]]);
  assert.deepEqual(fields[1].choices, ["small", "big"]);
  const repository = m.repositoryOf("https://github.com/alexec/agents");
  assert.deepEqual(m.createRequest("do", "agents-0a1f", repository, fields), {
    id: "do", name: "agents-0a1f", repository: "https://github.com/alexec/agents",
    options: { region: "nyc3", size: "small", disk: 20, spot: false },
  });
});

test("the words say what happens next", () => {
  const r = m.repositoryOf("https://github.com/alexec/agents");
  assert.match(m.machineWords.joining("agents-1", r), /clones alexec\/agents on its first boot/);
  assert.match(m.machineWords.notJoining("agents-1", "Codespaces"), /Add it as a machine in the Mac app/);
});

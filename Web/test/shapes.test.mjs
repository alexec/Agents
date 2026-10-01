// Every object Swift encoded into the fixtures has the shape the generated types give it (T042).
//
// Two checks. The top-level objects are held to `Shapes`: every required key there, and no key
// that is not listed. Then every fixture is type-checked by `tsc` as a literal of its type, which
// holds nested objects and the hand-written overrides (Packages/WebTypes/Overrides) to real JSON
// the same way: a key Swift writes that the type lacks, or a required one it leaves out, fails.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { load } from "./load.mjs";
import { cases, fixtures } from "./fixtures.mjs";

const { Shapes } = await load("src/protocol/generated.ts");
const web = fileURLToPath(new URL("..", import.meta.url));

/** What each notification in a reducer stream carries. */
const notified = {
  "agent/changed": "Agent", "agent/entry": "EntryNotification", "agent/permission": "PermissionNotification",
  "agent/elicitation": "ElicitationNotification", "agent/removed": "AgentRemovedNotification",
};

/** Every Swift-encoded object in the fixtures, with the type it was encoded as. */
function typed() {
  const found = [];
  const add = (type, value, where) => found.push({ type, value, where });
  for (const c of cases("groups/agents.json")) add("Agent", c.input.agent, `groups/agents ${c.name}`);
  for (const c of cases("groups/panels.json")) c.input.agents.forEach((a, i) => add("Agent", a, `groups/panels ${c.name} #${i}`));
  for (const c of cases("status/rows.json")) add("Agent", c.input.agent, `status/rows ${c.name}`);
  for (const c of cases("turns/transcripts.json")) {
    c.input.entries.forEach((e, i) => add("TranscriptEntry", e, `turns/transcripts ${c.name} #${i}`));
  }
  for (const c of cases("turns/lines.json")) add("ToolCall", c.input.call, `turns/lines ${c.name}`);
  for (const c of cases("background/words.json")) {
    c.input.items.forEach((item, i) => add("BackgroundItem", item, `background/words ${c.name} #${i}`));
  }
  for (const c of cases("labels/query.json")) add("Agent", c.input.agent, `labels/query ${c.name}`);
  for (const c of cases("reducer/streams.json")) {
    c.input.steps.forEach((step, i) => {
      if (step.notify) add(notified[step.notify.method], step.notify.params, `reducer ${c.name} #${i}`);
      if (step.page) add("TranscriptPage", step.page, `reducer ${c.name} #${i}`);
    });
  }
  for (const c of cases("options/drawable.json")) {
    [...c.input.agentOptions, ...c.input.draftOptions].forEach((x, i) => add("ConfigOption", x, `options ${c.name} #${i}`));
  }
  for (const file of readdirSync(fixtures + "overrides").filter((f) => f.endsWith(".json"))) {
    const type = file.replace(/\.json$/, "");
    for (const c of cases(`overrides/${file}`)) add(type, c.input, `overrides/${type} ${c.name}`);
  }
  return found;
}

const all = typed();

test("every fixture type is known", () => {
  assert.ok(all.length > 100);
  assert.deepEqual(all.filter((t) => !t.type), []);
});

test("every top-level object has exactly the keys Shapes gives its type", () => {
  const problems = [];
  for (const { type, value, where } of all) {
    const shape = Shapes[type];
    if (!shape) continue; // An override: tsc holds it below.
    const keys = Object.keys(value);
    const allowed = new Set([...shape.required, ...shape.optional]);
    const missing = shape.required.filter((key) => !(key in value));
    const unknown = keys.filter((key) => !allowed.has(key));
    if (missing.length || unknown.length) problems.push(`${where} (${type}): missing ${missing}, unknown ${unknown}`);
  }
  assert.deepEqual(problems, []);
});

test("every fixture type-checks as its generated type, nested objects and overrides too", () => {
  const folder = mkdtempSync(join(tmpdir(), "agents-shapes-"));
  try {
    const generated = join(web, "src/protocol/generated.ts").replace(/\.ts$/, "");
    const types = [...new Set(all.map((t) => t.type))];
    const lines = [
      `import type { Base64, ResourceName, URLString, UUID, WireDate, ${types.join(", ")} } from ${JSON.stringify(generated)};`,
      // The wire's strings and numbers are branded in TypeScript; JSON carries them plain.
      "type Plain<T> = T extends UUID | URLString | Base64 | ResourceName ? string",
      "  : T extends WireDate ? number",
      "  : T extends readonly (infer U)[] ? Plain<U>[]",
      "  : T extends object ? { [K in keyof T]: Plain<T[K]> } : T;",
      ...all.map(({ type, value, where }, i) =>
        `// ${where.replace(/\n/g, " ")}\nexport const c${i}: Plain<${type}> = ${JSON.stringify(value)};`),
    ];
    writeFileSync(join(folder, "fixtures.ts"), lines.join("\n") + "\n");
    writeFileSync(join(folder, "tsconfig.json"), JSON.stringify({
      compilerOptions: { target: "es2022", module: "esnext", moduleResolution: "bundler", strict: true,
        exactOptionalPropertyTypes: true, verbatimModuleSyntax: true, noEmit: true, skipLibCheck: true, types: [] },
      files: ["fixtures.ts"],
    }));
    let output = "";
    try {
      execFileSync(join(web, "node_modules/.bin/tsc"), ["-p", folder], { encoding: "utf8", stdio: "pipe" });
    } catch (error) {
      output = `${error.stdout ?? ""}${error.stderr ?? ""}`;
    }
    assert.equal(output, "", output.split("\n").slice(0, 20).join("\n"));
  } finally {
    rmSync(folder, { recursive: true, force: true });
  }
});

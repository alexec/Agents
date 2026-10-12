// Personas (#760), held to Persona.choices.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const p = await load("src/model/personas.ts");
const pick = (...values) => values.map((value) => ({ value, name: value }));
const advertised = [
  { id: "mode", name: "Mode", category: "mode", type: "select", currentValue: "default", options: pick("default", "plan") },
  { id: "model", name: "Model", category: "model", type: "select", currentValue: "opus", options: pick("opus", "haiku") },
  { id: "fast", name: "Fast", type: "boolean", currentValue: false },
];
const reviewer = {
  id: "reviewer", name: "Reviewer", origin: "project",
  settings: { permissionMode: "plan", model: "sonnet", options: { fast: "true" }, labels: ["review", "Bugs"] },
};

test("each key the runtime offers applies on its own; one it lacks is left alone", () => {
  assert.deepEqual(p.personaChoices(reviewer, advertised), { mode: "plan", fast: true });
});

test("a persona naming nothing changes nothing", () => {
  assert.deepEqual(p.personaChoices({ ...reviewer, settings: { options: {}, labels: [] } }, advertised), {});
});

test("its labels go beside those already there, each once", () => {
  assert.deepEqual(p.withPersonaLabels(["bugs"], reviewer), ["bugs", "review"]);
});

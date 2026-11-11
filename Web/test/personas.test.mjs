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
  id: "reviewer", name: "Reviewer", origin: "folder",
  settings: { permissionMode: "plan", model: "sonnet", options: { fast: "true" }, labels: ["review", "Bugs"] },
};

test("each key the runtime offers applies on its own; one it lacks is left alone", () => {
  assert.deepEqual(p.personaChoices(reviewer, advertised), { mode: "plan", fast: true });
});

test("a persona naming nothing changes nothing", () => {
  assert.deepEqual(p.personaChoices({ ...reviewer, settings: { options: {}, labels: [] } }, advertised), {});
});

test("its labels go beside those already there, each once", () => {
  assert.deepEqual(p.withPersonaLabels(["bugs"], undefined, reviewer), ["bugs", "review"]);
});

const engineer = { ...reviewer, id: "engineer", name: "Engineer", settings: { options: {}, labels: ["code", "bugs"] } };

test("switching persona takes the last one's labels away, keeping those both name (#2649)", () => {
  assert.deepEqual(p.withPersonaLabels(["mine", "review", "Bugs"], reviewer, engineer), ["mine", "Bugs", "code"]);
});

test("no persona takes the last one's labels away and keeps the person's", () => {
  assert.deepEqual(p.withPersonaLabels(["mine", "review", "Bugs"], reviewer, undefined), ["mine"]);
});

// Auto (#4559), held to PersonaAutoPickTests.
const persona = (id, name, keywords) => ({ id, name, origin: "folder", settings: { options: {}, labels: [] }, keywords });
const all = [
  persona("product-owner", "Product Owner", ["what about", "idea", "should we", "file an issue"]),
  persona("scrum-master", "Scrum Master", ["lanes", "land", "PRs", "merge"]),
  persona("software-engineer", "Software Engineer", ["fix", "build", "implement", "#<n>"]),
];
const picked = (text) => p.autoPersona(text, all)?.persona.id;

test("a whole keyword picks its persona, and names the word", () => {
  assert.deepEqual(p.autoPersona("What about a dark mode?", all)?.word, "what about");
  assert.equal(picked("What about a dark mode?"), "product-owner");
});

test("a half-typed word picks nothing", () => {
  assert.equal(picked("fi"), undefined);
  assert.equal(picked("fix"), undefined);
  assert.equal(picked("fix "), "software-engineer");
  assert.equal(picked("fixing it "), undefined);
});

test("case does not matter, and the file's word is shown", () => {
  assert.equal(picked("land the prs, then stop"), "scrum-master");
  assert.equal(p.autoPersona("land the prs, then stop", all)?.word, "land");
});

test("most matches wins; the earliest breaks a tie", () => {
  assert.equal(picked("An idea: merge the PRs and land them."), "scrum-master");
  assert.equal(picked("What about an issue for the lanes "), "product-owner");
});

test("an issue number is a word", () => {
  assert.equal(p.autoPersona("Take #4559.", all)?.word, "#4559");
  assert.equal(picked("Take #4559"), undefined);
  assert.equal(picked("Take a#1 "), undefined);
});

test("no match, or a broken file, is no persona", () => {
  assert.equal(picked("Tell me a joke."), undefined);
  assert.equal(picked(""), undefined);
  assert.equal(p.autoPersona("fix it", [{ ...all[2], problem: "x" }]), undefined);
});

test("with no keywords, its name and description are the words", () => {
  const reviewer = { ...persona("reviewer", "Reviewer"), description: "Reads every change for security bugs." };
  assert.deepEqual(p.autoWords(reviewer), ["Reviewer", "Reads", "change", "security"]);
  assert.equal(p.autoPersona("A security check, please", [reviewer])?.word, "security");
});

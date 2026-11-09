// Secrets follow the person across machines; fixed-scope settings have no switch here.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const u = await load("src/model/userScope.ts");

test("user scope: a secret's row says where it is, and a removed machine it was on", () => {
  assert.equal(u.machines({ machines: [] }), "On no machine yet");
  assert.equal(u.machines({ machines: ["a"] }), "On 1 machine");
  assert.equal(u.machines({ machines: ["a", "b"] }), "On 2 machines");
  assert.equal(u.leftOn({}), null);
  assert.match(u.leftOn({ leftOn: [{ host: "b", name: "Sam's box", at: "2026-10-21T15:00:00Z" }] }), /^It was on Sam's box, which was removed/);
  assert.equal(u.secretsLeft({ host: "b", name: "Sam's box", secrets: ["A", "B"] }),
    "Sam's box was removed with these secrets on it: A, B. Change them where they were issued.");
});

test("user scope: a secret's row says what it is for, and an empty field sends none (#4167)", () => {
  assert.equal(u.about(undefined), "No description");
  assert.equal(u.about("  "), "No description");
  assert.equal(u.about(" A token for alexec/Agents. "), "A token for alexec/Agents.");
  assert.deepEqual(u.describedAs("  "), {});
  assert.deepEqual(u.describedAs(" The shop. "), { description: "The shop." });
});

test("user scope: a secret's name is an environment variable's", () => {
  assert.equal(u.isSecretName("GITHUB_TOKEN"), true);
  assert.equal(u.isSecretName("github_token"), false);
  assert.equal(u.isSecretName("../X"), false);
  assert.equal(u.isSecretName(""), false);
});

test("user scope: the ~/.agents editors say they are this Mac's, and what goes to the other machines (#2704)", () => {
  assert.equal(u.thisMacOnly, "This Mac's");
  assert.match(u.agentConfigurationFollows, /^Your other machines get this Mac's instructions/);
  assert.match(u.agentConfigurationFollows, /Workflows, plugins and a skill's other files stay on this Mac\.$/);
});

test("user scope: a card is one value of its parts, as the window writes it (#3531)", () => {
  const card = u.tidyCard({ number: "4242 4242 4242 4242", expiry: "9/2031", cvc: "737", name: " Sam Lee ", zip: "94110" });
  assert.equal(u.cardProblem(card), null);
  assert.equal(u.cardValue(card), '{"cvc":"737","expiry":"09/31","name":"Sam Lee","number":"4242424242424242","zip":"94110"}');
  assert.equal(u.tidyExpiry("0931"), "09/31");
  const ok = { number: "4242424242424242", expiry: "09/31", cvc: "737", name: "S", zip: "1" };
  assert.equal(u.cardProblem({ ...ok, number: "4242424242424241" }), "The card number is not right.");
  assert.equal(u.cardProblem({ ...ok, expiry: "13/31" }), "Write the expiry as MM/YY.");
  assert.equal(u.cardProblem({ ...ok, cvc: "73" }), "The CVC is 3 or 4 digits.");
  assert.equal(u.cardProblem({ ...ok, name: "" }), "Write the name on the card.");
  assert.match(u.cardRule, /has a spend limit, such as a Privacy.com card. A card locked to one merchant or category is safer/);
});

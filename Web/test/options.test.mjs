// The prompt's menus, as Swift draws them (research R7).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";
import { cases } from "./fixtures.mjs";

const o = await load("src/model/options.ts");

for (const { name, input, expected } of cases("options/drawable.json")) {
  test(`options: ${name}`, () => {
    const drawn = o.drawable(input.agentOptions, input.draftOptions);
    const mode = o.modeOption(drawn);
    const remembered = input.remembered === null ? undefined : input.remembered;
    assert.deepEqual({
      drawn: drawn.map((x) => x.id),
      permission: drawn.filter(o.isAboutPermission).map((x) => x.id),
      titles: drawn.map((x) => o.closedTitle(x)),
      mode: mode?.id ?? null,
      modeStartsOn: mode ? o.modeStartsOn(remembered, mode) ?? null : null,
    }, expected);
  });
}

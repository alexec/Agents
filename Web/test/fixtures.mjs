// The cases Swift wrote for the ports (Packages/AgentsKit/Tests/AgentsKitTests/Fixtures/web,
// research R7). Each is { name, input, expected }.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

export const fixtures = fileURLToPath(new URL("../../Packages/AgentsKit/Tests/AgentsKitTests/Fixtures/web/", import.meta.url));

export function cases(path) {
  return JSON.parse(readFileSync(fixtures + path, "utf8"));
}

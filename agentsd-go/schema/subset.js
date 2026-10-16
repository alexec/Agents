// The DaemonAPI subset stages 1–2 use: every definition reachable from these roots.
const fs = require("fs");
const all = require("./bootstrap/all.schema.json");
const roots = ["Agent", "TranscriptEntry", "TranscriptPage", "TurnsPage", "ProjectSummary", "RuntimeStatus",
  "PermissionRequest", "ListRequest", "StartRequest", "PromptRequest", "OptionsResponse"];
const keep = new Set();
const walk = (v) => {
  if (Array.isArray(v)) return v.forEach(walk);
  if (v && typeof v === "object") {
    if (typeof v.$ref === "string") {
      const name = decodeURIComponent(v.$ref.replace("#/definitions/", ""));
      if (!keep.has(name)) { keep.add(name); walk(all.definitions[name]); }
    }
    Object.values(v).forEach(walk);
  }
};
roots.forEach((r) => { keep.add(r); walk(all.definitions[r]); });
const definitions = {};
[...keep].sort().forEach((k) => (definitions[k] = all.definitions[k]));
// What the TypeScript could only say in a comment, said in the schema.
definitions.UUID = { ...definitions.UUID, format: "uuid", pattern: "^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$" };
if (definitions.WireDate) definitions.WireDate["x-swift-type"] = "Date";
const schema = { $schema: "http://json-schema.org/draft-07/schema#", $id: "https://agents.alexecollins.com/schema/daemon-subset.json",
  title: "DaemonAPI subset (spike #1125, stages 1–2)",
  // A root naming every type, for generators that start from one (quicktype).
  type: "object", properties: Object.fromEntries(roots.map((r) => [r[0].toLowerCase() + r.slice(1), { $ref: "#/definitions/" + r }])),
  definitions };
fs.writeFileSync("daemon.schema.json", JSON.stringify(schema, null, 2) + "\n");
console.log(Object.keys(definitions).length, "definitions of", Object.keys(all.definitions).length);

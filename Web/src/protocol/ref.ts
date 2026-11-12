// A ref (#4727, spec 4724-event-bus, "A ref"): provider:type:topic#id, such as
// github:pr:alexec/agents#4702 or agents:machine:#mac-mini. The same parser as Go's wire.Ref
// (Go/wire/ref.go) and Swift's WireRef; Web/test/ref.test.mjs holds it to the same rows.
import type { Ref } from "./generated";

/** A ref's parts: provider, type and topic lower case; the id keeps its case. */
export interface RefParts {
  provider: string;
  type: string;
  topic: string;
  id: string;
}

/** What a short form leaves out: the folder's origin and the forge's answer. */
export interface RefContext {
  /** The folder's origin, such as github and alexec/agents. */
  provider?: string;
  topic?: string;
  /** The forge's answer for a number whose form does not say its type ("pr", "issue"). */
  typeOf?: (provider: string, topic: string, id: string) => string | undefined;
}

export const maxRefLength = 512;

const word = /^[a-z0-9-]+$/;
const usage = "want provider:type:topic#id, such as github:pr:alexec/agents#4702";

/** Says what is wrong with a ref's parts, or undefined. */
export function checkRef(r: RefParts): string | undefined {
  if (!word.test(r.provider)) return `provider "${r.provider}": want lower case letters, digits and -`;
  if (!word.test(r.type)) return `type "${r.type}": want lower case letters, digits and -`;
  if (/[:#]/.test(r.topic)) return `topic "${r.topic}": holds : or #`;
  if (r.topic !== r.topic.toLowerCase()) return `topic "${r.topic}": want lower case`;
  if (r.id === "") return "no id after #";
  if (formatRef(r).length > maxRefLength) return `longer than ${maxRefLength} characters`;
  return undefined;
}

/** The full form, provider:type:topic#id. */
export function formatRef(r: RefParts): Ref {
  return `${r.provider}:${r.type}:${r.topic}#${r.id}` as Ref;
}

/** Reads the full form, lowering the case of provider, type and topic; throws otherwise. */
export function parseRef(s: string): RefParts {
  if (s.length > maxRefLength) throw new Error(`ref: longer than ${maxRefLength} characters`);
  const hash = s.indexOf("#");
  const [provider, type, topic, ...more] = hash < 0 ? [] : s.slice(0, hash).split(":");
  if (provider === undefined || type === undefined || topic === undefined || more.length > 0) throw new Error(`ref "${s}": ${usage}`);
  const r = { provider: provider.toLowerCase(), type: type.toLowerCase(), topic: topic.toLowerCase(), id: s.slice(hash + 1) };
  const wrong = checkRef(r);
  if (wrong) throw new Error(`ref "${s}": ${wrong}`);
  return r;
}

/** A provider's type for a pull request: "mr" on GitLab, "pr" elsewhere. */
export function pullType(provider: string): string {
  return provider.toLowerCase() === "gitlab" ? "mr" : "pr";
}

/**
 * Reads a ref as a person types it and gives the full ref: the full form, `#123` and `P#123`
 * (the origin's topic), `owner/repo#123` (the origin's provider) and lineage's
 * `github:owner/repo#123`. The forge says the type when the form does not.
 */
export function parseShortRef(input: string, c: RefContext = {}): RefParts {
  const s = input.trim();
  if (s.length > maxRefLength) throw new Error(`ref: longer than ${maxRefLength} characters`);
  const hash = s.indexOf("#");
  const head = hash < 0 ? "" : s.slice(0, hash);
  const id = hash < 0 ? "" : s.slice(hash + 1);
  if (id === "") throw new Error(`ref "${s}": want provider:type:topic#id, #123, P#123 or owner/repo#123`);
  const colons = head.split(":").length - 1;
  let provider: string;
  let topic: string;
  let type = "";
  if (colons === 2) return parseRef(s);
  if (colons === 1) {
    const colon = head.indexOf(":");
    provider = head.slice(0, colon);
    topic = head.slice(colon + 1);
  } else if (head === "" || head.toUpperCase() === "P") {
    if (!c.provider || !c.topic) throw new Error("ref: the short form needs the folder's origin (provider and topic)");
    provider = c.provider;
    topic = c.topic;
    if (head !== "") type = pullType(provider);
  } else if (head.includes("/")) {
    if (!c.provider) throw new Error("ref: the short form needs the folder's origin (provider and topic)");
    provider = c.provider;
    topic = head;
  } else {
    throw new Error(`ref "${s}": want provider:type:topic#id, #123, P#123 or owner/repo#123`);
  }
  provider = provider.toLowerCase();
  topic = topic.toLowerCase();
  if (type === "") {
    type = c.typeOf?.(provider, topic, id) ?? "";
    if (type === "") throw new Error(`ref ${provider}:${topic}#${id}: the forge must say whether it is an issue or a pull request`);
  }
  const r = { provider, type: type.toLowerCase(), topic, id };
  const wrong = checkRef(r);
  if (wrong) throw new Error(`ref "${s}": ${wrong}`);
  return r;
}

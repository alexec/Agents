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

const cutLast = (s: string, sep: string): [string, string] | undefined => {
  const i = s.lastIndexOf(sep);
  return i <= 0 || i + sep.length === s.length ? undefined : [s.slice(0, i), s.slice(i + sep.length)];
};

const tryParse = (s: string): RefParts | undefined => {
  try {
    return parseRef(s);
  } catch {
    return undefined;
  }
};

/**
 * A lineage node's ref in the form it had before #4800, given the node's kind, as the full ref:
 * the same rows as Go's wire.RefFromLineage. A ref in the full form is read as parseRef reads it.
 * Undefined for a form it does not know. topic is the project of an agents node, which the old
 * form did not say; it can be empty.
 */
export function refFromLineage(kind: string, old: string, topic = ""): RefParts | undefined {
  const full = tryParse(old);
  if (full) return full;
  const colon = old.indexOf(":");
  const scheme = colon < 0 ? "" : old.slice(0, colon);
  const rest = colon < 0 ? "" : old.slice(colon + 1);
  if (rest === "" || !word.test(scheme)) return undefined;
  const project = topic.toLowerCase();
  let r: RefParts | undefined;
  if (kind === "session" && scheme === "session") r = { provider: "agents", type: "session", topic: project, id: rest };
  else if (kind === "workflow" && scheme === "workflow") r = { provider: "agents", type: "workflow", topic: project, id: rest };
  else if (kind === "workflow-run" && scheme === "run") r = { provider: "agents", type: "workflow-run", topic: project, id: rest };
  else if (kind === "issue" && (scheme === "linear" || scheme === "jira")) {
    const dash = rest.indexOf("-");
    if (dash <= 0) return undefined;
    r = { provider: scheme, type: "issue", topic: rest.slice(0, dash).toLowerCase(), id: rest };
  } else if (kind === "pr" && scheme === "gitlab" && rest.includes("!")) {
    const i = rest.lastIndexOf("!");
    r = { provider: scheme, type: "mr", topic: rest.slice(0, i).toLowerCase(), id: rest.slice(i + 1) };
  } else if (kind === "issue" || kind === "pr") {
    const i = rest.lastIndexOf("#");
    if (i < 0) return undefined;
    r = { provider: scheme, type: kind === "pr" ? pullType(scheme) : kind, topic: rest.slice(0, i).toLowerCase(), id: rest.slice(i + 1) };
  } else if (kind === "release" || kind === "milestone") {
    const cut = cutLast(rest, `/${kind}/`);
    if (!cut) return undefined;
    r = { provider: scheme, type: kind, topic: cut[0].toLowerCase(), id: cut[1] };
  } else if (kind === "doc" && scheme === "file") r = { provider: "file", type: "doc", topic: "", id: rest };
  else if (kind === "doc" && (scheme === "https" || scheme === "http")) {
    const tail = rest.replace(/^\/\//, "");
    const slash = tail.indexOf("/");
    const host = slash < 0 ? tail : tail.slice(0, slash);
    if (host === "") return undefined;
    r = { provider: "web", type: "doc", topic: host.toLowerCase(), id: "/" + (slash < 0 ? "" : tail.slice(slash + 1)) };
  } else if (kind === "doc") {
    const i = rest.indexOf("/doc/");
    if (i < 0) return undefined;
    r = { provider: scheme, type: "doc", topic: rest.slice(0, i).toLowerCase(), id: rest.slice(i + "/doc/".length) };
  } else if (kind === "ci-run") {
    const cut = cutLast(rest, "/actions/run/") ?? cutLast(rest, "/pipelines/") ?? cutLast(rest, "/builds/");
    if (!cut) return undefined;
    r = { provider: scheme, type: "run", topic: cut[0].toLowerCase(), id: cut[1] };
  } else if (kind === "deploy") {
    const i = rest.lastIndexOf("/");
    if (i <= 0) return undefined;
    r = { provider: scheme, type: "deploy", topic: rest.slice(0, i).toLowerCase(), id: rest.slice(i + 1) };
  } else if (kind === "target" && scheme === "target") {
    const c = rest.indexOf(":");
    if (c < 0) return undefined;
    r = { provider: rest.slice(0, c), type: "target", topic: "", id: rest.slice(c + 1).toLowerCase() };
  } else if (kind === "health" && scheme === "sentry") {
    const slash = rest.indexOf("/");
    if (slash < 0) return undefined;
    r = { provider: scheme, type: "issue", topic: rest.slice(0, slash).toLowerCase(), id: rest.slice(slash + 1) };
  } else if (kind === "health") r = { provider: scheme, type: "incident", topic: "", id: rest };
  else if (kind === "repo" && !rest.includes("#")) r = { provider: scheme, type: "repo", topic: "", id: rest.toLowerCase() };
  return r && checkRef(r) === undefined ? r : undefined;
}

/** A lineage ref with no kind, in either form: the full form, or the old form of a release
 * (…/release/<tag>), a GitLab merge request (!), a session or an issue. */
export function anyLineageRef(ref: string): RefParts | undefined {
  const full = tryParse(ref);
  if (full) return full;
  const kind = ref.startsWith("session:") ? "session" : ref.includes("/release/") ? "release"
    : ref.startsWith("gitlab:") && ref.includes("!") ? "pr" : "issue";
  return refFromLineage(kind, ref);
}

/** A node's ref, parsed, in either form. */
export const nodeRef = (n: { kind: string; ref: string }): RefParts | undefined => refFromLineage(n.kind, n.ref) ?? anyLineageRef(n.ref);

/** The session id of a session's ref: agents:session:<topic>#<id>, or session:<id> in the old form. */
export function sessionIdOf(ref: string): string | undefined {
  const r = refFromLineage("session", ref);
  return r && r.provider === "agents" && r.type === "session" ? r.id : undefined;
}

/** A session's ref as a client names it: it does not know the project, so the topic is empty; the
 * daemon names the node as it keeps it (#4800). */
export const sessionRef = (id: string) => `agents:session:#${id}`;

/** A repo's ref in either form: github:repo:#alexec/agents, or the old github:alexec/agents. */
export function repoRefOf(repo: string): RefParts | undefined {
  const r = refFromLineage("repo", repo);
  return r && r.type === "repo" ? r : undefined;
}

/** The ref of the repo or tracker a ref is in: github:repo:#alexec/agents of github:issue:alexec/agents#12. */
export function repoOfRef(r: RefParts): RefParts | undefined {
  if (r.type === "repo") return r;
  return r.topic === "" ? undefined : { provider: r.provider, type: "repo", topic: "", id: r.topic };
}

/** The old lineage form of a ref (before #4800), which the page's words and addresses are made
 * from: github:alexec/agents#12 of github:issue:alexec/agents#12, session:<id> of a session. A ref
 * in the old form, or one it does not know, is as it is. */
export function legacyRef(ref: string): string {
  const r = tryParse(ref);
  if (!r) return ref;
  const { provider: p, type, topic, id } = r;
  if (p === "agents") return type === "session" ? `session:${id}` : type === "workflow" ? `workflow:${id}` : type === "workflow-run" ? `run:${id}` : ref;
  switch (type) {
    case "issue":
      if (p === "linear" || p === "jira") return `${p}:${id}`;
      if (p === "sentry") return `sentry:${topic}/${id}`;
      return `${p}:${topic}#${id}`;
    case "pr": return `${p}:${topic}#${id}`;
    case "mr": return `${p}:${topic}!${id}`;
    case "release": case "milestone": return `${p}:${topic}/${type}/${id}`;
    case "doc":
      if (p === "file") return `file:${id}`;
      if (p === "web") return `https://${topic}${id === "/" ? "" : id}`;
      return `${p}:${topic}/doc/${id}`;
    case "run": {
      const mark = p === "gitlab" || p === "bitbucket" ? "/pipelines/" : p === "azuredevops" ? "/builds/" : "/actions/run/";
      return `${p}:${topic}${mark}${id}`;
    }
    case "deploy": return `${p}:${topic}/${id}`;
    case "target": return `target:${p}:${id}`;
    case "incident": return `${p}:${id}`;
    case "repo": return `${p}:${id}`;
    default: return ref;
  }
}

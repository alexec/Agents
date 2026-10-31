// The organisation's ways to the model (#999, spec 999): org keys and gateways, kept by the control plane with
// their secrets sealed. The words are OrgAccountWords (Packages/AgentsKit/.../Runtimes/OrgAccountWords.swift) on
// the Mac and the Remote; the same here. Below them, Console ▸ Model Access's form: a route as the fields an admin
// types in, with each kind's settings and secret fields, and back to a route. A value is written, never read back.
import type { OrgRoute, OrgRouteKind, OrgRouteMine, OrgRouteSettings, OrgRouteVendor } from "../protocol/generated";
import { runtimeName } from "./orgPolicy";

export { reachChoiceNames, reachChoiceOf, reachChoices, reachName, reachOf, reachWords, termsChoices, termsNames } from "./orgPolicy";
export type { ReachChoice } from "./orgPolicy";

export const fromOrganisation = "From your organisation";
export const noPlanLimit = "Organisation · No plan limit";
export const routesTitle = "Your Organisation’s Ways to the Model";
export const noRoutes = "Your organisation gives you no key or gateway. Each runtime uses your own sign-in.";
export const routesFoot = "Your organisation keeps the keys. No client shows them, and the runtime never has them: it reaches the model through a relay on your machine.";

export const kinds: readonly OrgRouteKind[] = ["key", "bedrock", "vertex", "azure", "baseURL"];
export const kindNames: Record<OrgRouteKind, string> = {
  key: "Org key", bedrock: "Amazon Bedrock", vertex: "Google Vertex AI", azure: "Microsoft Azure", baseURL: "Gateway",
};
export const vendorNames: Record<OrgRouteVendor, string> = { anthropic: "Anthropic", openai: "OpenAI", xai: "xAI" };

export function kindName(kind: string): string {
  return kindNames[kind as OrgRouteKind] ?? kind;
}

/** Each runtime's kinds: the spec's table "What each runtime can use" (the control plane's orgRouteKinds). */
export const runtimeKinds: Record<string, readonly OrgRouteKind[]> = {
  claude: ["key", "bedrock", "vertex", "azure", "baseURL"],
  codex: ["key", "azure", "baseURL"],
  opencode: ["key", "bedrock", "vertex", "azure", "baseURL"],
};
/** The API each runtime speaks, for a key, Azure or base-URL route (orgRouteVendors). */
export const runtimeVendors: Record<string, readonly OrgRouteVendor[]> = {
  claude: ["anthropic"], codex: ["openai"], opencode: ["anthropic", "openai"],
};
/** The runtimes whose model traffic the machine's relay can carry. */
export const routeRuntimes: readonly string[] = Object.keys(runtimeKinds).sort((a, b) => runtimeName(a).localeCompare(runtimeName(b)));

/** Whether a kind needs a vendor: whose API it speaks. */
export function needsVendor(kind: OrgRouteKind): boolean {
  return kind === "key" || kind === "azure" || kind === "baseURL";
}

/** The runtimes a route of this kind and vendor can serve. */
export function runtimesFor(kind: OrgRouteKind, vendor: OrgRouteVendor | undefined): string[] {
  return routeRuntimes.filter((id) => runtimeKinds[id]!.includes(kind) && (!needsVendor(kind) || (vendor !== undefined && runtimeVendors[id]!.includes(vendor))));
}

/** The vendors a kind can speak, for at least one runtime. */
export function vendorsFor(kind: OrgRouteKind): OrgRouteVendor[] {
  if (!needsVendor(kind)) return [];
  const out = new Set<OrgRouteVendor>();
  for (const id of routeRuntimes) if (runtimeKinds[id]!.includes(kind)) for (const v of runtimeVendors[id]!) out.add(v);
  return [...out];
}

export interface Field<K extends string> {
  key: K;
  label: string;
  placeholder?: string;
  /** A field of several lines: a service account's JSON. */
  long?: boolean;
}

type SettingKey = keyof OrgRouteSettings;

/** Each kind's settings that are not secret, in the form's order. */
export const settingFields: Record<OrgRouteKind, readonly Field<SettingKey>[]> = {
  key: [],
  bedrock: [{ key: "region", label: "AWS region", placeholder: "us-east-1" }],
  vertex: [{ key: "project", label: "Google Cloud project", placeholder: "acme-ai" }, { key: "location", label: "Location", placeholder: "us-east5" }],
  azure: [
    { key: "resource", label: "Resource", placeholder: "acme-openai" },
    { key: "address", label: "Or its address", placeholder: "acme.openai.azure.com, with https" },
    { key: "apiVersion", label: "API version", placeholder: "Leave empty for the newest" },
    { key: "tenant", label: "Entra tenant", placeholder: "For an Entra app" },
    { key: "clientID", label: "Entra client id", placeholder: "For an Entra app" },
  ],
  baseURL: [{ key: "address", label: "Address", placeholder: "llm.acme.dev, with https" }, { key: "header", label: "Header for the key", placeholder: "Authorization" }],
};

/** Each kind's secret fields (the control plane's routeSecretFields), written only. */
export const secretFields: Record<OrgRouteKind, readonly Field<string>[]> = {
  key: [{ key: "apiKey", label: "API key" }],
  baseURL: [{ key: "apiKey", label: "Key" }],
  bedrock: [
    { key: "apiKey", label: "Bedrock API key" },
    { key: "awsAccessKeyId", label: "Or an AWS access key id" },
    { key: "awsSecretAccessKey", label: "And its secret" },
    { key: "awsRoleArn", label: "Role to assume (optional)" },
    { key: "externalId", label: "External id (optional)" },
  ],
  vertex: [{ key: "serviceAccount", label: "Service account key (JSON)", long: true }],
  azure: [{ key: "apiKey", label: "Azure key" }, { key: "entraClientSecret", label: "Or an Entra app’s secret" }],
};

/** A route's line for a member: "Amazon Bedrock · Claude, OpenCode · default for Claude". */
export function mineLine(route: OrgRouteMine): string {
  const parts = [kindName(route.kind), route.runtimes.map(runtimeName).join(", ")];
  if (route.defaultFor.length > 0) parts.push(`default for ${route.defaultFor.map(runtimeName).join(", ")}`);
  return parts.join(" · ");
}

// The refusals of the contract (contracts/org-routes-api.md), for the chat lines of slice 3.

export function requires(runtime: string, route: string): string {
  return `Your organisation requires ${runtimeName(runtime)} to use ${route}.`;
}
export const antigravityRefused = "Your organisation does not allow Antigravity, because of Google’s terms on third-party tools.";
export const routeMissing = "Your organisation’s way to this model has not reached this machine. Connect to the network.";
export function routeRemoved(name: string): string {
  return `Your organisation removed ${name}.`;
}

// Console ▸ Model Access: the route as the fields an admin types in.

export interface RouteForm {
  name: string;
  kind: OrgRouteKind;
  vendor: OrgRouteVendor | "";
  runtimes: string[];
  settings: Partial<Record<SettingKey, string>>;
  /** Written only: empty keeps the value the route has. */
  secrets: Record<string, string>;
  /** "claude-sonnet-4-5 = us.anthropic.claude-sonnet-4-5-v1:0", one a line. */
  models: string;
  /** Empty: everyone. */
  groups: string[];
  defaultFor: string[];
}

export function newRouteForm(): RouteForm {
  return { name: "", kind: "key", vendor: "anthropic", runtimes: ["claude"], settings: {}, secrets: {}, models: "", groups: [], defaultFor: [] };
}

export function routeFormOf(r: OrgRoute): RouteForm {
  const settings: Partial<Record<SettingKey, string>> = {};
  for (const [k, v] of Object.entries(r.settings ?? {})) if (typeof v === "string") settings[k as SettingKey] = v;
  return {
    name: r.name, kind: r.kind, vendor: r.vendor ?? "", runtimes: [...r.runtimes], settings, secrets: {},
    models: Object.entries(r.models ?? {}).map(([from, to]) => `${from} = ${to}`).join("\n"),
    groups: [...(r.groups ?? [])], defaultFor: [...(r.defaultFor ?? [])],
  };
}

/**
 * The route the fields say, on top of the one loaded (its id, and fields of a newer control plane, kept), and the
 * secrets typed. A setting or a runtime that this kind does not take is left out. Or why not, in words.
 */
export function routeOf(form: RouteForm, base: OrgRoute | undefined): { route: OrgRoute; secrets: Record<string, string> } | { problem: string } {
  const name = form.name.trim();
  if (name === "") return { problem: "Give the route a name that members will see, such as Acme Bedrock." };
  const vendor = needsVendor(form.kind) && form.vendor !== "" ? form.vendor : undefined;
  if (needsVendor(form.kind) && !vendor) return { problem: "Say whose API the route speaks." };
  const can = runtimesFor(form.kind, vendor);
  const runtimes = form.runtimes.filter((id) => can.includes(id));
  if (runtimes.length === 0) return { problem: `Choose the runtimes it is for: ${kindName(form.kind)} can serve ${can.map(runtimeName).join(", ") || "none"}.` };
  const settings: OrgRouteSettings = {};
  for (const f of settingFields[form.kind]) {
    const v = form.settings[f.key]?.trim();
    if (v) settings[f.key] = v;
  }
  const models: Record<string, string> = {};
  for (const line of form.models.split("\n").map((l) => l.trim()).filter((l) => l !== "")) {
    const m = /^(\S+)\s*(?:=|→|->)\s*(\S+)$/.exec(line);
    if (!m) return { problem: `“${line}” is not a model and its id on the gateway, as claude-sonnet-4-5 = us.anthropic.claude-sonnet-4-5-v1:0.` };
    models[m[1]!] = m[2]!;
  }
  const secrets: Record<string, string> = {};
  for (const f of secretFields[form.kind]) {
    const v = form.secrets[f.key]?.trim();
    if (v) secrets[f.key] = v;
  }
  // An id of "" is made from the name at add.
  const route: OrgRoute = base ? { ...structuredClone(base), name, kind: form.kind, runtimes } : { id: "", name, kind: form.kind, runtimes };
  if (vendor) route.vendor = vendor;
  else delete route.vendor;
  if (Object.keys(settings).length > 0) route.settings = settings;
  else delete route.settings;
  if (Object.keys(models).length > 0) route.models = models;
  else delete route.models;
  route.groups = [...form.groups];
  route.defaultFor = form.defaultFor.filter((id) => runtimes.includes(id));
  // The count the control plane adds for an admin; it sets the rest itself.
  delete route.machines;
  return { route, secrets };
}

/** Each secret field's short name, beside its fingerprint. */
export const secretNames: Record<string, string> = {
  apiKey: "Key", awsAccessKeyId: "AWS access key", awsSecretAccessKey: "AWS secret", awsRoleArn: "Role", externalId: "External id",
  serviceAccount: "Service account", entraClientSecret: "Entra secret",
};

/** "Key 1a2b3c4d · serviceAccount 9f8e7d6c": the short fingerprint of each value set (spec D14). */
export function fingerprintWords(r: OrgRoute): string {
  const prints = Object.entries(r.fingerprint ?? {});
  if (prints.length === 0) return "No key";
  return prints.map(([field, print]) => `${secretNames[field] ?? field} ${print}`).join(" · ");
}

/** "Everyone", or the groups' names. */
export function whoWords(r: OrgRoute, groupName: (id: string) => string | undefined): string {
  if (!r.groups || r.groups.length === 0) return "Everyone";
  return r.groups.map((g) => groupName(g) ?? g).join(", ");
}

/** "Held by 3 machines", "Held by no machine". */
export function heldWords(r: OrgRoute): string {
  const n = r.machines ?? 0;
  return n === 0 ? "Held by no machine" : n === 1 ? "Held by 1 machine" : `Held by ${n} machines`;
}

export const noSealing = "This control plane has no key to seal secrets with, so it keeps no route with a key. Start it with a key file or AGENTS_CONTROL_KMS. A gateway with no key can still be added.";
export const modelAccessFoot = "A key is sealed on the control plane and sent to each machine that may use it, sealed to that machine. No client shows it again, admins included: compare the fingerprint. The runtime gets a stand-in and reaches the model through a relay on its machine.";

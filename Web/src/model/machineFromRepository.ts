// Start a Machine from a Repository (#1809): pick a repository, pick a provider that makes
// machines, start. The control plane gives the repository to the provider (Codespaces makes the
// codespace from it) or has the new host clone it once it joins, and the folder shows then.
// The window's and the Remote's MachineFromRepository words are the same.
import type { JSONValue, ProviderCreate, ProviderID, ProviderSummary } from "../protocol/generated";

/** An https repository address, as the control plane takes one (repositoryPath in providers.go). */
export interface Repository {
  url: string;
  /** owner/name, or group/subgroup/name. */
  path: string;
  /** The last part, without `.git`. */
  name: string;
}

export function repositoryOf(text: string): Repository | null {
  const url = text.trim();
  if (!url || /\s/.test(url)) return null;
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return null;
  }
  if (parsed.protocol !== "https:" || !parsed.hostname || parsed.username || parsed.password || parsed.search) return null;
  const path = parsed.pathname.replace(/^\/+|\/+$/g, "").replace(/\.git$/, "");
  if (!path.includes("/") || path.includes("//")) return null;
  return { url, path, name: path.split("/").pop()! };
}

/**
 * A host name for the machine: the repository's name in letters, digits and dashes, starting
 * with a letter, and a short `suffix` so a second machine from it has a name of its own.
 */
export function machineName(repository: string, suffix: string): string {
  let base = repository.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
  if (!/^[a-z]/.test(base)) base = `m-${base}`.replace(/-+$/, "");
  return `${base.slice(0, 30).replace(/-+$/, "")}-${suffix}`;
}

/** Four hex digits for machineName. */
export function nameSuffix(random: () => number = Math.random): string {
  return Math.floor(random() * 0x10000).toString(16).padStart(4, "0");
}

/** The providers that can make a machine. */
export function makers(providers: readonly ProviderSummary[]): ProviderSummary[] {
  // Only those the person may start machines from (#1761); a control plane before groups lets everyone.
  return providers.filter((p) => p.capabilities.includes("create") && p.mayUse !== false);
}

/** One field of a provider's New Workspace form, a flat JSON Schema object's property. */
export interface FormField {
  key: string;
  title: string;
  kind: "string" | "integer" | "boolean";
  choices?: string[];
  value: string;
  description?: string;
}

/** The form's fields, but `repository`, which the repository fills. */
export function formFields(schema: JSONValue | undefined): FormField[] {
  const properties = (schema as { properties?: Record<string, Record<string, unknown>> } | null)?.properties ?? {};
  return Object.entries(properties).filter(([key]) => key !== "repository").map(([key, p]) => {
    const kind = p["type"] === "integer" || p["type"] === "number" ? "integer" : p["type"] === "boolean" ? "boolean" : "string";
    const field: FormField = { key, title: typeof p["title"] === "string" ? p["title"] : key, kind,
      value: p["default"] === undefined ? "" : String(p["default"]) };
    if (Array.isArray(p["enum"])) field.choices = p["enum"].map(String);
    if (typeof p["description"] === "string") field.description = p["description"];
    return field;
  });
}

/** What Start sends: providers/create with the repository, if any (#2131), and the form's values, typed. */
export function createRequest(provider: string, name: string, repository: Repository | null, fields: readonly FormField[]): ProviderCreate {
  const options: Record<string, JSONValue> = {};
  for (const f of fields) {
    const v = f.value.trim();
    if (!v) continue;
    options[f.key] = f.kind === "integer" ? Number(v) : f.kind === "boolean" ? v === "true" : v;
  }
  const request: ProviderCreate = { id: provider as ProviderID, name, options };
  if (repository) request.repository = repository.url;
  return request;
}

export const machineWords = {
  title: "Start a Machine from a Repository",
  menuItem: "Start a Machine from a Repository…",
  repositoryPrompt: "The repository’s https address",
  repositoryNote: (r: Repository | null, typed: boolean) => r ? `The machine clones ${r.path} and adds it as a folder.`
    : typed ? "Give an https address of a repository, such as on GitHub or GitLab." : "The repository to work in.",
  noMakers: "No provider here can make a machine. Add DigitalOcean, Compute Engine or Codespaces in Settings ▸ Machine providers.",
  start: "Start",
  starting: (name: string) => `Starting ${name}…`,
  joining: (name: string, r: Repository) => `${name} is starting. It installs Agents, joins and clones ${r.path} on its first boot. The folder shows when it has.`,
  notJoining: (name: string, provider: string) => `${provider} made ${name}, but can't install Agents on its first boot. Add it as a machine in the Mac app: Settings ▸ Machine Providers, Add as Machine….`,
  privateNote: "A private repository needs git access on the new machine.",
};

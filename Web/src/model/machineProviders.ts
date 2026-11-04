// Settings ▸ Machine Providers on the web (#1808), as the window's ControlProvidersPage:
// each machine provider as a card of its workspaces, Add Provider, Edit, List Again, Remove,
// and a workspace's host linked, started and stopped. Only the providers that work through
// their API with a token (#1119) are offered here: a CLI preset needs its CLI signed in where
// the control plane runs, and a person who starts in a browser has no shell there.
import type { ControlMachine, ProviderAdd, ProviderSummary, MachineInfo } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";

export type ProviderKind = "digitalOcean" | "codespaces" | "coder" | "aws" | "compute";

export const providerKinds: readonly ProviderKind[] = ["digitalOcean", "codespaces", "coder", "aws", "compute"];

/** One field of a kind's form. A secret goes only to the control plane, never in the configuration. */
export interface ProviderField {
  id: string;
  label: string;
  prompt?: string;
  secret?: true;
  optional?: true;
  value?: string;
}

interface KindInfo {
  title: string;
  preset: string;
  needs: string;
  fields: ProviderField[];
}

/** The window's titles and needs (AddProviderSheet.Kind), for the API way only. */
const kinds: Record<ProviderKind, KindInfo> = {
  digitalOcean: {
    title: "DigitalOcean Droplets",
    preset: "digitalocean-api",
    needs: "Needs a DigitalOcean API token with custom scopes: droplet read and update, and droplet create and delete to make and delete droplets. Nothing to install.",
    fields: [
      { id: "token", label: "API token", secret: true },
      { id: "tag", label: "Tag", value: "agents" },
      { id: "user", label: "ssh user", value: "root" },
    ],
  },
  codespaces: {
    title: "GitHub Codespaces",
    preset: "codespaces-api",
    needs: "Needs a GitHub token: fine-grained, with Codespaces lifecycle admin (read and write), or classic, with the codespace scope. ssh still goes through gh where the control plane runs.",
    fields: [
      { id: "token", label: "GitHub token", secret: true },
      { id: "repo", label: "Repository", prompt: "owner/name, or empty for all", optional: true },
    ],
  },
  coder: {
    title: "Coder Workspaces",
    preset: "coder-api",
    needs: "Needs your deployment’s address and a session token (`coder tokens create`). ssh still goes through coder where the control plane runs.",
    fields: [
      { id: "url", label: "Deployment", prompt: "Your deployment’s address" },
      { id: "token", label: "Session token", secret: true },
    ],
  },
  aws: {
    title: "AWS EC2 Instances",
    preset: "aws-ec2-api",
    needs: "Needs an IAM user’s access key, with the smallest policy: ec2:DescribeInstances on all resources, and ec2:StartInstances and ec2:StopInstances only on instances that have the tag (the condition aws:ResourceTag/‹tag› not Null). Nothing to install.",
    fields: [
      { id: "accessKey", label: "Access key ID", secret: true },
      { id: "secretKey", label: "Secret access key", secret: true },
      { id: "region", label: "Region", prompt: "us-east-1" },
      { id: "tag", label: "Tag", value: "agents" },
      { id: "user", label: "ssh user", value: "ec2-user" },
    ],
  },
  compute: {
    title: "Google Compute Engine VMs",
    preset: "gcp-compute-api",
    needs: "Needs a service account’s JSON key, with the smallest role: compute.instances.list, start and stop, and for New Machine… compute.instances.create, delete, setMetadata and setLabels, compute.disks.create, and compute.subnetworks.use and useExternalIp. ssh goes to each VM’s external address, so the network must let in port 22, and a static address keeps it the same after a stop (#1691). Nothing to install.",
    fields: [
      { id: "serviceKey", label: "Service account key (JSON)", secret: true },
      { id: "project", label: "Project" },
      { id: "zone", label: "Zone", prompt: "europe-west2-a" },
      { id: "label", label: "Label", value: "agents" },
      { id: "user", label: "ssh user", value: "agents" },
      { id: "sshKey", label: "ssh public key", optional: true },
    ],
  },
};

export const providerWords = {
  heading: "Machine providers",
  /** Under the list: what a provider is, and the kinds only the Mac app adds (#3425). */
  footer: (hasMac: boolean) => "A provider starts and stops your machines: DigitalOcean Droplets, GitHub Codespaces, Coder workspaces, "
    + "Google Compute Engine VMs or AWS EC2 instances, through their API. It runs on the control plane, so it can start a machine that is down. "
    + (hasMac ? "Docker, Cloud Workstations, your own commands and MCP servers are added in the Mac app."
      : "The web page cannot add Docker, Cloud Workstations, your own commands or MCP servers yet."),
  off: "Machine providers are off on this control plane.",
  add: "Add Provider…",
  secretsFoot: "Tokens and keys go to the control plane and are never shown again. This page does not keep them.",
  editSecret: "Leave empty to keep the one it has.",
  removeTitle: (name: string) => `Remove ${name}?`,
  removeNote: "Its machines stay as they are, unlinked: nothing here can start or stop them any more.",
  noHosts: "No machine to link: add one in Settings ▸ Machines, with Add a Machine…, or start one from a repository.",
  notAHostYet: "Not joined yet, and it gives no ssh destination: add it with the command from Add a Machine…, then Link to Machine….",
  addAsMachine: "Add as Machine…",
  addAsMachineHelp: "Installs Agents on it over ssh, and links the machine to it.",
  startFirst: "Start it first: it has to be running to be installed.",
  installNote: (provider: string) => `The control plane installs Agents on it over its own ssh, and links the machine to it, so ${provider} starts it again.`,
  installing: "Installing Agents… This takes a minute or two.",
  linking: "Linking… This reads the machine’s ssh host key.",
  linkTrustNote: (fingerprint: string) => `This machine’s host key is new to the control plane: ${fingerprint}. Link only if this is the key the machine shows (ssh-keygen -lf on its host key): its provider starts it over ssh with this key.`,
  trustNote: (fingerprint: string) => `This machine’s host key is new to the control plane: ${fingerprint}. Install only if this is the key the machine shows (ssh-keygen -lf on its host key).`,
  installed: (name: string) => `Installed on ${name}. It is linked to this machine when it joins.`,
};

export function kindTitle(kind: ProviderKind): string { return kinds[kind].title; }
export function kindNeeds(kind: ProviderKind): string { return kinds[kind].needs; }

/** A kind's fields, with their starting values. */
export function kindFields(kind: ProviderKind): ProviderField[] { return kinds[kind].fields.map((f) => ({ ...f })); }

/** The kind a preset stands for, when it is one this page can add or edit. */
export function kindOfPreset(preset: string | undefined): ProviderKind | undefined {
  return providerKinds.find((k) => kinds[k].preset === preset);
}

/** The name a new provider gets when the person gives none: its kind's title. */
export function defaultName(kind: ProviderKind): string { return kinds[kind].title; }

/**
 * What Add or Save sends: `providers/add`, or with `editing` `providers/update`. On an edit the
 * configuration is left out, so the control plane keeps it, and an empty secret keeps the one it
 * has. Answers a sentence that says what is missing, or the request.
 */
export function providerRequest(kind: ProviderKind, name: string, values: Record<string, string>, editing?: ProviderSummary): ProviderAdd | string {
  const v = (id: string) => (values[id] ?? "").trim();
  const title = name.trim() || defaultName(kind);
  const secretNames: Record<string, string> = kind === "aws"
    ? { accessKey: "AWS_ACCESS_KEY_ID", secretKey: "AWS_SECRET_ACCESS_KEY" }
    : kind === "compute" ? { serviceKey: "GOOGLE_SERVICE_ACCOUNT_KEY" }
    : { token: { digitalOcean: "DIGITALOCEAN_API_TOKEN", codespaces: "GITHUB_TOKEN", coder: "CODER_SESSION_TOKEN" }[kind] };
  const secrets: Record<string, string> = {};
  for (const [field, secret] of Object.entries(secretNames)) {
    // The secret key is not trimmed: a key is what it is.
    const value = field === "secretKey" || field === "serviceKey" ? (values[field] ?? "") : v(field);
    if (value) secrets[secret] = value;
    else if (!editing) return `Give the ${kinds[kind].fields.find((f) => f.id === field)?.label ?? field}.`;
  }
  if (editing) return { id: editing.id, name: title, kind: "commands", secrets };
  const commands: Record<string, string | string[]> = { preset: kinds[kind].preset };
  switch (kind) {
    case "digitalOcean":
      commands["tag"] = v("tag") || "agents";
      commands["user"] = v("user") || "root";
      break;
    case "codespaces":
      if (v("repo")) commands["repo"] = v("repo");
      break;
    case "coder":
      if (!v("url")) return "Give the deployment’s address.";
      commands["url"] = v("url");
      break;
    case "aws":
      if (!v("region")) return "Give the region.";
      commands["region"] = v("region");
      commands["tag"] = v("tag") || "agents";
      commands["user"] = v("user") || "ec2-user";
      break;
    case "compute":
      if (!v("project") || !v("zone")) return "Give the project and the zone.";
      commands["project"] = v("project");
      commands["zone"] = v("zone");
      commands["label"] = v("label") || "agents";
      commands["user"] = v("user") || "agents";
      if (v("sshKey")) commands["sshKeys"] = [v("sshKey")];
      break;
  }
  return { name: title, kind: "commands", commands, secrets };
}

/** The chip on a card, as the window's: "command provider · digitalocean-api · API". */
export function kindChip(provider: ProviderSummary): string {
  if (provider.preset) return `command provider · ${provider.preset} · ${provider.preset.endsWith("-api") ? "API" : "CLI"}`;
  return provider.kind === "commands" ? "command provider" : provider.mapped ? "MCP server · mapped" : "MCP server";
}

/** The grey line under a provider's name, as the window's providerLine. */
export function providerLine(provider: ProviderSummary, time: (at: Date) => string): string {
  const parts: string[] = [];
  if (provider.problem && (!provider.current || provider.listedAt == null)) parts.push(`Couldn’t list: ${provider.problem}`);
  if (provider.listedAt != null) parts.push(`${provider.current ? "Listed" : "Showing what it listed at"} ${time(fromWireDate(provider.listedAt))}`);
  if (provider.workspaces.length === 0 && provider.listedAt != null) parts.push("No machines");
  // Only when the machine that runs it has no such CLI (#3367).
  if (provider.sshToolMissing) parts.push(`needs ${provider.sshToolMissing} for ssh`);
  return parts.join(" · ");
}

function capitalized(word: string): string { return word.slice(0, 1).toUpperCase() + word.slice(1); }

/** The grey line under a workspace, as the window's workspaceLine. */
export function workspaceLine(workspace: MachineInfo, hosts: readonly ControlMachine[]): string {
  const parts = [capitalized(workspace.state)];
  parts.push(workspace.host ? `linked to ${hosts.find((h) => h.id === workspace.host)?.name ?? "a machine"}` : "not joined");
  if (workspace.cost) parts.push(workspace.cost);
  return parts.join(" · ");
}

/**
 * What a workspace with no host says when no host is free to link to it and it gives no ssh
 * destination (#1931): Add as Machine… cannot reach it, so the person is told the other way in.
 */
export function noHostLine(workspace: MachineInfo, hosts: readonly ControlMachine[]): string | undefined {
  return !workspace.host && !workspace.ssh && linkableHosts(workspace, hosts).length === 0 ? providerWords.notAHostYet : undefined;
}

/**
 * Add as Machine… on a workspace no host has (#3365), as the window's: offered when the provider
 * gives an ssh destination, and pressable only while it runs. Answers undefined when it is not
 * offered, else whether it can be pressed and its help line.
 */
export function addAsMachine(workspace: MachineInfo): { ready: boolean; help: string } | undefined {
  if (workspace.host || !workspace.ssh) return undefined;
  const ready = workspace.state === "running";
  return { ready, help: ready ? providerWords.addAsMachineHelp : providerWords.startFirst };
}

/** `alex@127.0.0.1 -p 2222`, as a provider may give it, as ssh takes it in one word (the window's sshDestination). */
export function sshDestination(destination: string): string {
  const words = destination.trim().split(/\s+/);
  if (words.length !== 3 || words[1] !== "-p" || !/^\d+$/.test(words[2]!)) return destination.trim();
  return `ssh://${words[0]}:${Number(words[2])}`;
}

/** Whether a host named `hostName` may be this workspace (MachineInfo.mayBe, #976). */
export function mayBe(workspace: MachineInfo, hostName: string): boolean {
  const host = hostName.toLowerCase();
  if (workspace.ssh && workspace.ssh.toLowerCase() === host) return true;
  const name = workspace.name.toLowerCase();
  if (!name) return false;
  return host === name || `.${host}.`.includes(`.${name}.`);
}

/**
 * The hosts Link to Machine can offer for a workspace no host has: those that run agents and
 * are linked to none, the ones that may be it by name first.
 */
export function linkableHosts(workspace: MachineInfo, hosts: readonly ControlMachine[]): ControlMachine[] {
  if (workspace.host) return [];
  const free = hosts.filter((h) => h.relay == null && !h.workspace);
  return [...free.filter((h) => mayBe(workspace, h.name)), ...free.filter((h) => !mayBe(workspace, h.name))];
}

/** The window's Stop when idle choices, in minutes; 0 is Off. */
export const idleChoices: readonly { minutes: number; label: string }[] = [
  { minutes: 0, label: "Off" },
  { minutes: 15, label: "After 15 minutes" },
  { minutes: 30, label: "After 30 minutes" },
  { minutes: 60, label: "After 1 hour" },
  { minutes: 120, label: "After 2 hours" },
];

/** WorkspaceLink.defaultIdleMinutes. */
export const defaultIdleMinutes = 30;

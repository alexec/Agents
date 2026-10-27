// Capabilities decide what a host can do (#1748, docs/explanation/versions.md): the page shows
// a feature only when the host's list has its capability, and says what a host too old for the
// control plane is missing. The words are the window's and the Remote's (UpdateWords.swift).
import type { ControlMachine, RequiredCapabilities } from "../protocol/generated";
import { DeclaredCapabilities } from "../protocol/capabilities.generated";

/** Beside a feature that the host does not have. */
export const hostNeedsUpdate = "This machine needs an update to do this.";

/**
 * Whether a host in `state` answers calls: `online`, or `needsUpdate`, which is connected and
 * serves what its list says (#1771). Its features are gated by `hostHas`.
 */
export function hostAnswers(state: string | undefined): boolean {
  return state === "online" || state === "needsUpdate";
}

/** Whether a host can do what `capability` names. True for a host that said no list, or one not listed. */
export function hostHas(hosts: readonly ControlMachine[], host: string, capability: string): boolean {
  const row = hosts.find((h) => h.id === host);
  return row?.capabilities?.includes(capability) ?? true;
}

/** "Agents 0.9 (Go)" for a host written in Go (#1134). */
export function versionWords(host: ControlMachine): string {
  return host.implementation === "go" ? `Agents ${host.version} (Go)` : `Agents ${host.version}`;
}

/** A host's state as a row says it: "Needs an update" for `needsUpdate`. */
export function stateWords(host: ControlMachine): string {
  if (host.state === "needsUpdate") return "Needs an update";
  // A delete's backup, before its workspace goes (#1815).
  if (host.state === "stopping" && host.workspace?.phase === "backing up") return "Backing up to delete";
  return host.state.charAt(0).toUpperCase() + host.state.slice(1);
}

/** What to update a host to, and the names it is missing; null for one that has the control plane's required set. */
export function missingWords(host: ControlMachine, controlVersion: string | undefined): string | null {
  if (!host.missing || host.missing.length === 0) return null;
  const to = controlVersion ? ` to Agents ${controlVersion}` : "";
  return `Update this machine${to}. It does not have ${host.missing.join(", ")}.`;
}

/** When this page does not have what the control plane requires of a client; null when it has it. */
export function appMissingWords(required: RequiredCapabilities | undefined, controlVersion: string): string | null {
  const mine: readonly string[] = DeclaredCapabilities["client"] ?? [];
  const missing = (required?.client ?? []).filter((c) => !mine.includes(c));
  if (missing.length === 0) return null;
  return `Update this page to Agents ${controlVersion} to use this control plane. It does not have ${missing.join(", ")}.`;
}

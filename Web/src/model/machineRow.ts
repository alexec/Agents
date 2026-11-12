// A machine's row in the Machines section (#3974), as the window's MachineRow (#3973): its dot, what
// its menu and swipes do, and what Delete and Remove ask first. A machine a provider made can start,
// stop and be deleted; a registered one can only be removed; This Mac has neither.
import type { ControlMachine, ProviderSummary, StartedMachinePreview } from "../protocol/generated";
import { addMachineWords } from "./addMachine";
import { makers } from "./machineFromRepository";
import { unpushedWords } from "./people";

/** The dot's colour: green online, amber and turning while it changes, grey and hollow stopped, red offline or failed. */
export type MachineDot = "online" | "busy" | "stopped" | "offline" | "attention";

export function machineDot(host: ControlMachine, online: boolean, starting: boolean): MachineDot {
  if (starting || host.state === "starting" || host.state === "stopping") return "busy";
  if (host.state === "needsUpdate") return "attention";
  if (online) return "online";
  if (host.state === "stopped") return "stopped";
  return "offline";
}

/** A row's icon (#4113), as the window's MachineIcon: its shape says the kind, its colour the state, so the row has no dot. */
export type MachineIconTone = "accent" | "busy" | "failure" | "attention" | "stopped";
export type MachineKind = "mac" | "cloud" | "rack";

/** The most urgent wins: busy, then red (offline, failed or a low disk), then amber, then grey, then the accent. */
export function machineIcon(dot: MachineDot, diskLow: boolean): MachineIconTone {
  if (dot === "busy") return "busy";
  if (dot === "offline" || diskLow) return "failure";
  if (dot === "attention") return "attention";
  if (dot === "stopped") return "stopped";
  return "accent";
}

/** A laptop for This Mac, a cloud for a machine a provider made, a rack for a registered one. */
export function machineKind(host: ControlMachine, macID: string): MachineKind {
  return host.id === macID ? "mac" : host.workspace ? "cloud" : "rack";
}

export interface MachineActions {
  start: boolean;
  stop: boolean;
  /** Delete…: the provider deletes it. */
  delete: boolean;
  /** Remove…: Agents forgets it; the computer stays. */
  remove: boolean;
}

/** What a row offers, in its menu and its swipes. */
export function machineActions(host: ControlMachine, macID: string): MachineActions {
  if (host.id === macID) return { start: false, stop: false, delete: false, remove: false };
  const ws = host.workspace;
  const changing = host.state === "starting" || host.state === "stopping";
  return {
    start: !!ws && ws.canStart && !changing && host.state !== "online" && host.state !== "needsUpdate",
    stop: !!ws && ws.canStop && !changing && (host.state === "online" || host.state === "needsUpdate"),
    delete: !!ws,
    remove: !ws,
  };
}

/** The swipe to the right: Start or Stop; to the left: Delete or Remove, which ask first. */
export function machineSwipes(actions: MachineActions): { leading: "start" | "stop" | null; trailing: "delete" | "remove" | null } {
  return {
    leading: actions.start ? "start" : actions.stop ? "stop" : null,
    trailing: actions.delete ? "delete" : actions.remove ? "remove" : null,
  };
}

/** How far a finger goes across a row before the swipe is taken, in CSS pixels. */
export const swipeDistance = 72;

/** Delete's question: it always asks, says how many sessions stop, and names the worktrees on it with work
 * not pushed (#3979), as the machine said them. */
export function deleteQuestion(host: ControlMachine, sessions: number, preview: StartedMachinePreview | null = null): string {
  const at = host.workspace?.providerName ? `${host.workspace.providerName} deletes` : "Its provider deletes";
  const stop = sessions === 0 ? "" : ` ${sessions === 1 ? "1 session" : `${sessions} sessions`} on it ${sessions === 1 ? "stops" : "stop"}.`;
  let work = "";
  if (preview?.unknown) work = ` ${preview.unknown}`;
  else if (preview && preview.unpushed.length > 0) {
    const count = preview.unpushed.length === 1 ? "1 worktree has" : `${preview.unpushed.length} worktrees have`;
    const folder = (url: string) => url.replace(/\/+$/, "").split("/").pop() ?? url;
    work = ` ${count} work not pushed, which is lost:\n${preview.unpushed.map((w) => `${folder(w.folder)} · ${unpushedWords(w)}`).join("\n")}`;
  }
  return `Delete ${host.name}? ${at} this machine and its disk.${stop}${work}`;
}

/** The Machines header's New Machine items (#3979): with two or more providers, New Machine names the default
 * and each other one has New Machine on ‹name›. `undefined` is the default provider. */
export function newMachineItems(providers: readonly ProviderSummary[]): { label: string; provider?: string }[] {
  const can = makers(providers);
  if (can.length < 2) return [{ label: "New Machine…" }];
  const chosen = can.find((p) => p.default) ?? can[0]!;
  return [{ label: `New Machine (${chosen.name})…` },
    ...can.filter((p) => p.id !== chosen.id).map((p) => ({ label: `New Machine on ${p.name}…`, provider: p.id as string }))];
}

/** Remove's question, as Settings ▸ Machines asked it. */
export function removeQuestion(host: ControlMachine): string {
  return `${addMachineWords.removeTitle(host.name)} ${addMachineWords.removeNote}`;
}

/** A machine New Machine made that has not joined yet (#4610), as the window's MachineMaking: Making… while the control
 * plane waits for it, the reason and Delete once it gave up. An empty provider is the page's own row, before the
 * control plane lists the machine. */
export interface MachineMaking {
  provider: string;
  providerName: string;
  workspace: string;
  name: string;
  notJoined: string | null;
}

/** The rows New Machine is making: each provider's workspaces the control plane waits for or gave up on, that no machine is
 * linked to and no machine of the name has joined; then the page's own names the list does not have yet. Making… first,
 * then by name. */
export function makingRows(making: readonly string[], providers: readonly ProviderSummary[] | null,
  hosts: readonly { name: string }[]): MachineMaking[] {
  const joined = (name: string) => hosts.some((h) => h.name === name);
  const rows: MachineMaking[] = [];
  for (const p of providers ?? []) {
    for (const w of p.workspaces) {
      if (w.host || !(w.joining || w.notJoined) || joined(w.name)) continue;
      rows.push({ provider: p.id, providerName: p.name, workspace: w.id, name: w.name, notJoined: w.notJoined ?? null });
    }
  }
  for (const name of making) {
    if (joined(name) || rows.some((r) => r.name === name)) continue;
    rows.push({ provider: "", providerName: "", workspace: "", name, notJoined: null });
  }
  return rows.sort((a, b) => {
    if ((a.notJoined === null) !== (b.notJoined === null)) return a.notJoined === null ? -1 : 1;
    return a.name.localeCompare(b.name);
  });
}

/** Delete's question on a row the control plane gave up on (#4610). */
export function deleteMakingQuestion(row: MachineMaking): string {
  return `Delete ${row.name}? ${row.providerName} deletes it. Nothing was installed on it, so there is nothing to back up.`;
}

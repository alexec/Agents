// A machine's row in the Machines section (#3974), as the window's MachineRow (#3973): its dot, what
// its menu and swipes do, and what Delete and Remove ask first. A machine a provider made can start,
// stop and be deleted; a registered one can only be removed; This Mac has neither.
import type { CapacityLevel, ControlMachine, ProviderSummary, StartedMachinePreview } from "../protocol/generated";
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

/** The most urgent wins: busy, then red (offline, failed, a low disk or at capacity), then amber (near capacity or an
 * update, #4748), then grey, then the accent. */
export function machineIcon(dot: MachineDot, diskLow: boolean, capacity?: CapacityLevel): MachineIconTone {
  if (dot === "busy") return "busy";
  if (dot === "offline" || diskLow || capacity === "full") return "failure";
  if (capacity === "near") return "attention";
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

/** A machine of the person's that has not joined (#4610, #4978), as the window's MachineMaking: Making… while the
 * control plane waits for one New Machine made, the reason and Delete once it gave up; grey and Not joined for one
 * Agents did not make (a codespace made on github.com, a stopped one), which a click joins. An empty provider is the
 * page's own row, before the control plane lists the machine. */
export interface MachineMaking {
  provider: string;
  providerName: string;
  workspace: string;
  name: string;
  notJoined: string | null;
  /** One New Machine did not make, or no longer waits for (#4978): a click joins it. */
  joinable: boolean;
  state: string;
  ssh: string | null;
  tunnel: boolean;
  /** Whether its provider can delete a machine (`delete` in its capabilities). */
  deletable: boolean;
}

/** How a click on a machine that never joined goes (#4978), as the window's MachineJoin. */
export type MachineJoin = { joining: string | null } | { needsTrust: string } | { failed: string };

/** The rows: each provider's workspaces that no machine is linked to and no machine of the name has joined; then the
 * page's own names the list does not have yet. Making… first, then the ones the control plane gave up on, then the ones
 * that never joined (#4978), each by name. A failed make is no machine. */
export function makingRows(making: readonly string[], providers: readonly ProviderSummary[] | null,
  hosts: readonly { name: string }[]): MachineMaking[] {
  const joined = (name: string) => hosts.some((h) => h.name === name);
  const rows: MachineMaking[] = [];
  for (const p of providers ?? []) {
    if (p.mayUse === false) continue;
    for (const w of p.workspaces) {
      if (w.host || w.state === "failed" || joined(w.name)) continue;
      rows.push({ provider: p.id, providerName: p.name, workspace: w.id, name: w.name, notJoined: w.notJoined ?? null,
        joinable: !(w.joining || w.notJoined), state: w.state, ssh: w.ssh ?? null, tunnel: w.tunnel ?? false,
        deletable: p.capabilities.includes("delete") });
    }
  }
  for (const name of making) {
    if (joined(name) || rows.some((r) => r.name === name)) continue;
    rows.push({ provider: "", providerName: "", workspace: "", name, notJoined: null, joinable: false, state: "starting",
      ssh: null, tunnel: false, deletable: false });
  }
  const rank = (r: MachineMaking) => r.joinable ? 2 : r.notJoined === null ? 0 : 1;
  return rows.sort((a, b) => rank(a) - rank(b) || a.name.localeCompare(b.name));
}

/** Whether a click can join it: one that never joined, with somewhere to ssh to. */
export function canJoin(row: MachineMaking): boolean {
  return row.joinable && !!row.ssh;
}

/** The words for a step of an install, as Add a Machine's sheet says them. */
export function joinStepWords(step: string | null, stopped = false): string {
  switch (step) {
    case "start": return "Starting it…";
    case "connect": return stopped ? "Starting it and connecting…" : "Connecting…";
    case "checkSystem": return "Checking the system…";
    case "setUp": return "Installing Agents…";
    default: return "Joining…";
  }
}

/** The grey line under the row: Making…, why it did not join, or how a join goes. */
export function makingLine(row: MachineMaking, join?: MachineJoin): string {
  if (!row.joinable) return row.notJoined ?? "Making…";
  if (join && "joining" in join) return joinStepWords(join.joining, row.state === "stopped");
  if (join && "failed" in join) return `Didn’t join: ${join.failed}`;
  if (join && "needsTrust" in join) return `Its ssh host key is new to the control plane: ${join.needsTrust}`;
  if (!canJoin(row)) return `Not joined. ${row.providerName} gives no ssh destination for it, so it can’t join from here.`;
  switch (row.state) {
    case "stopped": return "Stopped, not joined";
    case "starting": return "Starting, not joined";
    case "stopping": return "Stopping, not joined";
    default: return "Not joined";
  }
}

/** What a click does, for the row's title and its label; null when it can't join. */
export function joinHint(row: MachineMaking): string | null {
  if (!canJoin(row)) return null;
  return row.state === "stopped" || row.state === "stopping" ? `Starts ${row.name} and joins it` : `Joins ${row.name}`;
}

/** Whether the row is red: the control plane gave up on it, or its join failed. */
export function makingFailed(row: MachineMaking, join?: MachineJoin): boolean {
  return row.joinable ? !!join && "failed" in join : row.notJoined !== null;
}

/** The cloud's tone: amber while it is made or joins, red once it failed, grey for one that never joined. */
export function makingTone(row: MachineMaking, join?: MachineJoin): MachineIconTone {
  if (makingFailed(row, join)) return "failure";
  if (!row.joinable || (join && "joining" in join)) return "busy";
  return "stopped";
}

/** The question before a join trusts a host key new to the control plane (#4978). */
export function joinTrustQuestion(row: MachineMaking, fingerprint: string): string {
  return `Trust ${row.name}’s host key? The control plane has not seen this key before: ${fingerprint}. Join only if it is ${row.name}’s.`;
}

/** Whether its menu and a swipe to the left offer Delete: once the control plane gave up on it, and on one that never
 * joined, but not while New Machine makes it or a join runs, nor when its provider can't delete. */
export function makingCanDelete(row: MachineMaking, join?: MachineJoin): boolean {
  return row.deletable && (row.joinable || row.notJoined !== null) && !(join && "joining" in join);
}

/** Delete's question. Agents installed nothing on a machine it gave up on (#4610); one that never joined, such as a
 * codespace made on github.com, can hold the person's own work. */
export function deleteMakingQuestion(row: MachineMaking): string {
  return row.joinable
    ? `Delete ${row.name}? ${row.providerName} deletes ${row.name} and its disk. It never joined Agents, so it has no backup: work on it that is not pushed is lost.`
    : `Delete ${row.name}? ${row.providerName} deletes it. Nothing was installed on it, so there is nothing to back up.`;
}

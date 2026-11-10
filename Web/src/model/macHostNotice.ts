// Why this Mac's host is quiet, in the window's words (MacHostNotice.swift, #303, #666): the
// process is down, it is up and has no membership, its uplink keeps failing, or it isn't answering.
import { effect, signal, type ReadonlySignal } from "@preact/signals";
import type { MachineJoinStatus } from "../protocol/generated";
import { hostAnswers } from "./capabilities";

export type MacHostNotice =
  | { kind: "notRunning" }
  | { kind: "notJoined"; problem?: string | undefined }
  | { kind: "uplinkFailing"; problem: string }
  | { kind: "notAnswering" };

/**
 * `macState` is this Mac's row in `machines/list`; `join` is `control/status.thisMacHost`. Only a
 * control plane on this Mac reads the host's join file (`planeOnThisMac`: the plane's machine is
 * the Mac host's), so elsewhere a missing join is not "the process is down". Nil while it is online.
 */
export function decideMacHostNotice(planeOnThisMac: boolean, macState: string | undefined,
                                    join: MachineJoinStatus | undefined): MacHostNotice | null {
  if (join) {
    if (!join.member) return { kind: "notJoined", problem: join.problem };
    if (!join.connected) {
      if (join.problem?.trim()) return { kind: "uplinkFailing", problem: join.problem };
      return { kind: "notAnswering" };
    }
    // The join says connected and the control plane's list says otherwise.
    if (macState !== undefined && !hostAnswers(macState)) return { kind: "notAnswering" };
    return null;
  }
  if (!planeOnThisMac) return macState === undefined || hostAnswers(macState) ? null : { kind: "notAnswering" };
  // Beside this Mac, a live host writes its join: no report, and not online, is the process down.
  return hostAnswers(macState) ? null : { kind: "notRunning" };
}

export function macHostNoticeTitle(notice: MacHostNotice): string {
  switch (notice.kind) {
    case "notRunning": return "This Mac isn’t running as a machine";
    case "notJoined": return "This Mac hasn’t joined";
    case "uplinkFailing": return "This Mac can’t reach the control plane";
    case "notAnswering": return "This Mac isn’t answering";
  }
}

export function macHostNoticeDetail(notice: MacHostNotice): string {
  switch (notice.kind) {
    case "notRunning":
      return "In Agents on this Mac, Settings ▸ Machines ▸ This Mac says why, Repair there starts it again, and Copy Diagnostics there is what to send with a report.";
    case "notJoined":
      return notice.problem?.trim()
        ? `It’s running, and it has no membership. ${sentence(notice.problem)} In Agents on this Mac, press Try Again in Settings ▸ Machines ▸ This Mac.`
        : "It’s running, and it still needs to join. In Agents on this Mac, press Try Again in Settings ▸ Machines ▸ This Mac.";
    case "uplinkFailing":
      return `It’s running, and its link to the control plane keeps failing. ${sentence(notice.problem)} It’s trying again by itself; Help ▸ Diagnostics in Agents on this Mac says more.`;
    case "notAnswering":
      return "What’s listed is what it last said. The control plane is trying again by itself.";
  }
}

function sentence(problem: string): string {
  const trimmed = problem.trim();
  if (!trimmed) return "";
  const head = trimmed.charAt(0).toUpperCase() + trimmed.slice(1);
  return head.endsWith(".") ? head : `${head}.`;
}

/** How long a notice stays once the host reports it is back: a host that connects and drops again
 *  every few seconds would otherwise draw and remove the notice as fast as it retries. */
export const noticeHoldMs = 8000;

/**
 * `now`, but a notice that goes is kept for `holdMs` first, and goes only if none comes back
 * meanwhile: the footer line stays put while the uplink flaps, instead of flickering.
 */
export function steadyNotice(now: ReadonlySignal<MacHostNotice | null>, holdMs: number = noticeHoldMs): ReadonlySignal<MacHostNotice | null> {
  const shown = signal<MacHostNotice | null>(now.peek());
  let clearing: ReturnType<typeof setTimeout> | undefined;
  effect(() => {
    const notice = now.value;
    if (clearing !== undefined) { clearTimeout(clearing); clearing = undefined; }
    if (notice) { shown.value = notice; return; }
    if (shown.peek() === null) return;
    clearing = setTimeout(() => { clearing = undefined; shown.value = null; }, holdMs);
  });
  return shown;
}

// Who answers the Builds page's reads (#5327, spec 5166 "Where the timings live"): the control plane's copy of the
// person's machines' build timings (builds/historyAll and builds/runAll, capability builds.read/1, #5232), so the
// page has data while the Mac sleeps; or, with an older control plane, one machine's own store (builds/history and
// builds/run, #5177).
import type { BuildsHistory, BuildsHistoryRequest, BuildsRunAnswer, BuildsRunRequest, MachineRef, ReportScope } from "../protocol/generated";
import { Capability } from "../protocol/capabilities.generated";
import type { Store } from "./store";
import { CallFailed } from "../wire/link";

/** A machine, or null for the control plane's copy. */
export type BuildsFrom = MachineRef | null;

/** The person's own machines, as the page's reports/value read. */
const mine: ReportScope = { kind: "me" };

/** True when the control plane keeps the copy and answers the page. */
export const planeReadsBuilds = (store: Store): boolean => store.planeHas(Capability.buildsRead1);

export function readHistory(store: Store, ask: BuildsHistoryRequest, from: BuildsFrom): Promise<BuildsHistory> {
  return from === null ? store.link.call("builds/historyAll", { ...ask, scope: mine }) : store.link.call("builds/history", ask, from);
}

export function readRun(store: Store, ask: BuildsRunRequest, from: BuildsFrom): Promise<BuildsRunAnswer> {
  return from === null ? store.link.call("builds/runAll", { ...ask, scope: mine }) : store.link.call("builds/run", ask, from);
}

/** Why a read failed, in the words of who was asked. */
export function readProblem(e: unknown, from: BuildsFrom): string {
  if (!(e instanceof CallFailed)) return from === null ? "The control plane can’t be reached." : "The machine can’t be reached.";
  if (e.code === -32601) return "This machine does not read build timings. Update it to see them.";
  if (/no attempt/i.test(e.message)) {
    const who = from === null ? "The control plane’s copy" : "This machine";
    return `${who} no longer keeps this run’s jobs: it keeps 90 days, and a pull request’s steps for 14.`;
  }
  return e.message;
}

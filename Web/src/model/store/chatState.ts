// Part of the Work (#5384): chatState.
import { signal } from "@preact/signals";
import type { WorkflowSummary, Achievements, CapReached } from "../../protocol/generated";
import { dropCap } from "../teamGroups";
import { folderKey } from "../groups";
import { workflowRunsOn } from "../workflows";
import { achievementsSeen } from "../achievements";
import type { ChartHint } from "../chart";
import type { Work } from "./work";
import { type UsageRead } from "./shared";

export const chatStateMethods = {
  /** Hold how to draw a CSV as a chart (#836); the same hint again changes nothing. */
  noteChartHint(this: Work, host: string, path: string, hint: ChartHint | undefined): void {
    if (!hint) return;
    const key = `${host}|${path}`;
    const held = this.chartHints.peek()[key];
    if (held && JSON.stringify(held) === JSON.stringify(hint)) return;
    this.chartHints.value = { ...this.chartHints.peek(), [key]: hint };
  },
  chartHint(this: Work, host: string, path: string): ChartHint | undefined {
    return this.chartHints.value[`${host}|${path}`];
  },
  /** One folder's workflows: a reader redraws only when this folder's list changes. */
  folderWorkflows(this: Work, host: string, folder: string): WorkflowSummary[] {
    const key = `${host}|${folderKey(folder)}`;
    let slice = this.workflowSlices.get(key);
    if (!slice) {
      slice = signal(this.workflows.peek()[key] ?? []);
      this.workflowSlices.set(key, slice);
    }
    return slice.value;
  },
  /** User-scope workflows from this host, with their source Markdown for Settings. */
  userWorkflows(this: Work, host: string): WorkflowSummary[] {
    return Object.entries(this.workflows.value)
      .filter(([key]) => key.startsWith(`${host}|`))
      .flatMap(([, workflows]) => workflows)
      .filter((summary) => summary.scope === "user" && summary.content !== undefined);
  },
  /** Whether `loadWorkflows` has answered for this folder since it was opened. */
  workflowsKnown(this: Work, host: string, folder: string): boolean {
    return this.workflowsLoaded.has(`${host}|${folderKey(folder)}`);
  },
  writeWorkflows(this: Work, key: string, list: WorkflowSummary[] | undefined): void {
    if (list === undefined) {
      if (key in this.workflows.peek()) {
        const { [key]: _gone, ...rest } = this.workflows.value;
        this.workflows.value = rest;
      }
    } else {
      this.workflows.value = { ...this.workflows.value, [key]: list };
    }
    const slice = this.workflowSlices.get(key);
    if (slice) slice.value = list ?? [];
  },
  upsertWorkflow(this: Work, summary: WorkflowSummary, host: string): void {
    const key = `${host}|${folderKey(summary.workflow.folder)}`;
    // A folder not on screen keeps no list: the next open asks for the whole of it (#291).
    if (this.workflows.peek()[key] === undefined && !this.workflowHolds.has(key)) return;
    const list = (this.workflows.peek()[key] ?? []).filter((w) => w.workflow.workflowID !== summary.workflow.workflowID);
    this.writeWorkflows(key, [...list, summary]);
  },
  /** The machine id of the host being looked at, when the control plane has said it. */
  hostMachineID(this: Work, host: string): string | undefined {
    const id = this.hosts.peek().find((item) => item.id === host)?.machineID;
    return id ? id : undefined;
  },
  /**
   * Keep a workflow this host still runs (#317). A save that pins it to other computers
   * answers with the workflow, and putting that answer back would show a row this host
   * does not run.
   */
  placeWorkflow(this: Work, summary: WorkflowSummary, host: string): void {
    if (workflowRunsOn(summary.workflow.runsOn, this.hostMachineID(host))) this.upsertWorkflow(summary, host);
    else this.removeWorkflow(summary.workflow.workflowID, summary.workflow.folder, host);
  },
  removeWorkflow(this: Work, workflowID: string, folder: string, host: string): void {
    const key = `${host}|${folderKey(folder)}`;
    const held = this.workflows.peek()[key];
    if (held) this.writeWorkflows(key, held.filter((item) => item.workflow.workflowID !== workflowID));
  },
  takeAchievements(this: Work, host: string, achievements: Achievements): void {
    this.achievements.value = { ...this.achievements.value, [host]: achievements };
    achievementsSeen.take(achievements);
  },
  /** Keeps the time of a read of one of a host's usage figures (#5144). */
  usageRead(this: Work, host: string, what: UsageRead): void {
    this.usageReadAt.value = { ...this.usageReadAt.value, [host]: { ...this.usageReadAt.value[host], [what]: Date.now() } };
  },
  /** Whether the control plane said `capability` (#1748), from `control/status`: false until it has said its list. */
  planeHas(this: Work, capability: string): boolean {
    return this.plane.value?.capabilities?.includes(capability) ?? false;
  },
  /** Whether `host` is the person's Mac (#1501). */
  isMac(this: Work, host: string | undefined): boolean {
    return host !== undefined && host === this.macHostID.value;
  },
  /** OK on a cap notice (#2198): the cap stays as it is, and the notice goes. */
  dismissCap(this: Work, reached: CapReached) {
    this.capped.value = dropCap(reached, this.capped.value);
  },
  say(this: Work, sentence: string): void {
    if (this.problem.value === null) this.problem.value = sentence;
    else if (this.problem.value !== sentence && !this.problemsWaiting.includes(sentence)) this.problemsWaiting.push(sentence);
  },
  /** The shown problem's OK: the next one waiting, if any. */
  dismissProblem(this: Work): void {
    this.problem.value = this.problemsWaiting.shift() ?? null;
  },
  /** Lists and timers keyed by a host, let go with it (#291). */
  dropHostRecords(this: Work, host: string): void {
    const prefix = `${host}|`;
    for (const [key, timer] of this.pageSettle) if (key.startsWith(prefix)) { clearTimeout(timer); this.pageSettle.delete(key); }
    for (const key of [...this.workflowHolds.keys()]) if (key.startsWith(prefix)) this.workflowHolds.delete(key);
    for (const key of [...this.workflowsLoaded]) if (key.startsWith(prefix)) this.workflowsLoaded.delete(key);
    for (const [key, slice] of this.workflowSlices) if (key.startsWith(prefix)) slice.value = [];
    for (const key of [...this.slices.keys()]) if (key.startsWith(prefix)) this.slices.delete(key);
    for (const key of [...this.views.keys()]) if (key.startsWith(prefix)) this.views.delete(key);
    for (const key of [...this.byID.keys()]) if (key.startsWith(prefix)) this.byID.delete(key);
  },
};

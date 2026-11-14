// Part of the Work (#5384): hostRows.
import { batch, computed } from "@preact/signals";
import type { Agent, ControlMachine, MachineWorkspace, ElicitationRequest, PermissionRequest, KeptRequest, Request as PersonRequest } from "../../protocol/generated";
import { CallFailed } from "../../wire/link";
import { knowVersions } from "../errors";
import { folderKey } from "../groups";
import { blockLines, openBlock } from "../block";
import { waiting } from "../gitLending";
import { hostAnswers } from "../capabilities";
import type { Work } from "./work";
import { byAsked } from "./shared";

export const hostRowsMethods = {
  /** The hosts as listed, with when each one went down noted. */
  takeHosts(this: Work, hosts: ControlMachine[], now = Date.now()): void {
    const since: Record<string, number> = {};
    for (const host of hosts) if (!hostAnswers(host.state)) since[host.id] = this.downSince.value[host.id] ?? now;
    const still = waiting(hosts);
    batch(() => {
      this.hosts.value = hosts;
      this.downSince.value = since;
      this.gitAsksAnswered.value = new Set([...this.gitAsksAnswered.value].filter((id) => still.has(id)));
    });
    this.knowVersions();
  },
  /** The versions a refusal's words compare (#4096); `mac` is the person's Mac, as a call's route says it. */
  knowVersions(this: Work): void {
    const machines = this.hosts.value.filter((h) => h.version).map((h): [string, string] => [h.id, h.version]);
    const mac = this.hosts.value.find((h) => h.id === this.macHostID.value);
    if (mac?.version) machines.push(["mac", mac.version]);
    knowVersions(this.plane.value?.version, machines);
  },
  /**
   * Whether a prompt or a start sent to `host` now is kept rather than refused: it is linked to a
   * workspace that is stopped or starting, and starts when used (FR-020).
   */
  startsWhenUsed(this: Work, host: string): boolean {
    const row = this.hosts.value.find((h) => h.id === host);
    return !!row?.workspace?.startWhenUsed && (row.state === "stopped" || row.state === "starting");
  },
  /** The prompts kept for one agent, oldest first. */
  /** One request changed (#3864): an open one is kept, oldest first, an answered or dropped one goes. */
  placeRequest(this: Work, host: string, request: PersonRequest): void {
    const list = (this.personRequests.peek()[host] ?? []).filter((r) => r.id !== request.id);
    if (request.state === "open") list.push(request);
    this.personRequests.value = { ...this.personRequests.peek(), [host]: list.sort(byAsked) };
  },
  keptFor(this: Work, host: string, agentID: string): KeptRequest[] {
    return this.kept.value.filter((k) => k.host === host && k.kind === "prompt" && k.agentID === agentID);
  },
  /** The agent starts kept for one folder. */
  keptStarts(this: Work, host: string, folder: string): KeptRequest[] {
    return this.kept.value.filter((k) => k.host === host && k.kind === "start" && !!k.folder && folderKey(k.folder) === folderKey(folder));
  },
  /** A kept request, said by the control plane as it answered: shown at once, before `control/keptChanged`. */
  noteKept(this: Work, error: CallFailed): KeptRequest | null {
    const said = error.data as KeptRequest | undefined;
    if (!said || typeof said.id !== "string") return null;
    if (!this.kept.value.some((k) => k.id === said.id)) this.kept.value = [...this.kept.value, said];
    return said;
  },
  /** One host's row, or its state and workspace, as said now, in place of what was listed. */
  takeHostRow(this: Work, change: { id: string; state: string; workspace?: MachineWorkspace | undefined }): void {
    const hosts = this.hosts.value;
    const at = hosts.findIndex((h) => h.id === change.id);
    if (at < 0) return;
    const row: ControlMachine = { ...hosts[at]!, state: change.state };
    if (change.workspace) row.workspace = change.workspace;
    else delete row.workspace;
    this.takeHosts(hosts.map((h, i) => (i === at ? row : h)));
  },
  /** Whether a host answers: online, or held back for a reason the page says. */
  hostIsOnline(this: Work, host: string): boolean {
    return hostAnswers(this.hosts.value.find((h) => h.id === host)?.state);
  },
  /** One agent: what reads it is redrawn when it changes, not when any agent on its host does (#170). */
  agent(this: Work, host: string, session: string): Agent | undefined {
    const name = `${host}|${session}`;
    let found = this.byID.get(name);
    if (!found) {
      // A few are read at a time (the open chat, its panes); the rest are let go.
      if (this.byID.size >= 64) this.byID.clear();
      found = computed(() => (this.agents.value[host] ?? []).find((a) => a.id === session));
      this.byID.set(name, found);
    }
    return found.value;
  },
  /**
   * What a blocked agent waits on, as its row says it. Only an agent with an open block reads
   * its host's other agents, for their titles; any other row is not redrawn by them (#170).
   */
  waitsOf(this: Work, host: string, agent: Agent): string[] {
    return openBlock(agent) ? blockLines(agent, this.agents.value[host] ?? []) : [];
  },
  /** AgentsModel.isComingBack: whether the host is bringing this chat back by itself. */
  isComingBack(this: Work, host: string, agentID: string): boolean {
    return (this.resuming.value[host] ?? []).includes(agentID);
  },
  permissionsFor(this: Work, host: string, session: string): PermissionRequest[] {
    return (this.permissions.value[host] ?? []).filter((p) => p.agentID === session);
  },
  elicitationsFor(this: Work, host: string, session: string): ElicitationRequest[] {
    return (this.elicitations.value[host] ?? []).filter((e) => e.agentID === session);
  },
  /** Every agent the page holds, on every host. */
  allAgents(this: Work): Agent[] {
    return Object.values(this.agents.value).flat();
  },
};

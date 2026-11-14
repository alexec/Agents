// Part of the Work (#5384): agentLists.
import { batch, computed, signal, type Signal } from "@preact/signals";
import type { Agent } from "../../protocol/generated";
import { folderKey, folderPath as agentFolderPath, folderView, type FolderView } from "../groups";
import type { Work } from "./work";
import { sameAgents } from "./shared";

export const agentListsMethods = {
  /**
   * Every write to a host's agents. `touched` names the folders that changed; without it every
   * folder of the host is worked out again, and only those whose agents differ are told.
   */
  setAgents(this: Work, host: string, heard: Agent[], touched?: readonly string[]): void {
    const prefix = `${host}|`;
    // What is pending is drawn over the host's records here, on every way in (#4786).
    const list = heard.map((a) => this.pending.overlay(host, a));
    batch(() => {
      this.agents.value = { ...this.agents.value, [host]: list };
      if (touched) {
        for (const folder of new Set(touched)) {
          const slice = this.slices.get(prefix + folder);
          if (slice) slice.value = list.filter((a) => agentFolderPath(a) === folder);
        }
        return;
      }
      const grouped = new Map<string, Agent[]>();
      for (const agent of list) {
        const folder = agentFolderPath(agent);
        const group = grouped.get(folder);
        if (group) group.push(agent); else grouped.set(folder, [agent]);
      }
      for (const [name, slice] of this.slices) {
        if (!name.startsWith(prefix)) continue;
        const next = grouped.get(name.slice(prefix.length)) ?? [];
        if (!sameAgents(slice.peek(), next)) slice.value = next;
      }
    });
  },
  slice(this: Work, host: string, folder: string): Signal<Agent[]> {
    const name = `${host}|${folder}`;
    let slice = this.slices.get(name);
    if (!slice) {
      slice = signal((this.agents.peek()[host] ?? []).filter((a) => agentFolderPath(a) === folder));
      this.slices.set(name, slice);
    }
    return slice;
  },
  /** One folder's agents, newest first: what reads them is redrawn only when they change. */
  folderAgents(this: Work, host: string, folder: string): Agent[] {
    return this.slice(host, folderKey(folder)).value;
  },
  /** One folder's headings, archived sessions, subtitle and counts, worked out once per change to it. */
  folderView(this: Work, host: string, folder: string): FolderView {
    const key = folderKey(folder);
    const name = `${host}|${key}`;
    let view = this.views.get(name);
    if (!view) {
      const slice = this.slice(host, key);
      view = computed(() => folderView(slice.value, key));
      this.views.set(name, view);
    }
    return view.value;
  },
  /** Which conversation's entries are kept. A change clears the page. */
  watch(this: Work, host: string, session: string): void {
    const now = this.watching.value;
    if (now?.host === host && now.session === session) return;
    batch(() => {
      this.watching.value = { host, session };
      this.clearTranscript();
      this.dropAnsweredSends();
    });
  },
  unwatch(this: Work): void {
    batch(() => {
      this.watching.value = null;
      this.clearTranscript();
      this.dropAnsweredSends();
    });
  },
};

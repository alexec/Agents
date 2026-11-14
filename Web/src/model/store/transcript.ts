// Part of the Work (#5384): transcript.
import { batch } from "@preact/signals";
import type { EntryNotification, TranscriptEntry, TranscriptPage, TurnsPage } from "../../protocol/generated";
import { artifactsIn, withArtifactsOf } from "../artifacts";
import { DisplayBuilder } from "../turns";
import { personPrompts } from "../sessionPrompts";
import { hostHas } from "../capabilities";
import { landed, type Sending } from "../sending";
import { type MachineCopy, type TranscriptCopy } from "../localCopy";
import { mark } from "../marks";
import type { Work } from "./work";
import { openingTurns, historyEntriesCap, historyTurnsCap, heardSincePageLimit, entriesKept, entriesTrimmedAt, itemsKept, turnsKept, keepingLatestByID, isAskEntry } from "./shared";

export const transcriptMethods = {
  /** The prompts on their way to an agent, as its chat draws them (#4814). */
  sendingTo(this: Work, host: string, agentID: string): Sending[] {
    return this.sending.value[`${host}|${agentID}`] ?? [];
  },
  setSending(this: Work, host: string, agentID: string, going: Sending[]): void {
    const { [`${host}|${agentID}`]: _was, ...rest } = this.sending.peek();
    this.sending.value = going.length > 0 ? { ...rest, [`${host}|${agentID}`]: going } : rest;
  },
  /** Answered ones wait for their chat's next entry: a chat left will not hear it. */
  dropAnsweredSends(this: Work): void {
    const held = this.sending.peek();
    if (!Object.values(held).some((going) => going.some((s) => s.answered))) return;
    this.sending.value = Object.fromEntries(Object.entries(held)
      .map(([key, going]) => [key, going.filter((s) => !s.answered)] as const)
      .filter(([, going]) => going.length > 0));
  },
  /**
   * Told of an entry too big for its host to send (#203): its stub holds its place, drawing
   * nothing, until the page reads it with `agents/transcript` and hands it to `fillOversized`.
   */
  oversized(this: Work, _host: string, _agentID: string, _entryID: string, _index: number | undefined): void {},
  /** An entry its host sent as a stub, read whole: put where its stub is. */
  fillOversized(this: Work, entry: TranscriptEntry, host: string, agentID: string): void {
    const watching = this.watching.value;
    if (!watching || watching.host !== host || watching.session !== agentID) return;
    const heard = this.heardSincePage?.findIndex((e) => e.id === entry.id) ?? -1;
    if (heard >= 0) this.heardSincePage![heard] = entry;
    const at = this.entries.value.findIndex((e) => e.id === entry.id);
    if (at < 0) return;
    const entries = [...this.entries.value];
    entries[at] = entry;
    this.refold(entries);
  },
  takeEntry(this: Work, note: EntryNotification, host: string): void {
    const watching = this.watching.value;
    if (!watching || watching.host !== host || watching.session !== note.agentID) return;
    const going = this.sending.peek()[`${host}|${note.agentID}`];
    if (going?.length) this.setSending(host, note.agentID, landed(going, note.entry));
    if (note.oversized !== undefined) this.oversized(host, note.agentID, note.entry.id, note.index);
    // The first entry after a send is its echo: the night's walk times send to echo (#4784).
    if (this.echoAwaited) {
      this.echoAwaited = false;
      mark("echo", "send");
    }
    const heard = this.heardSincePage;
    if (heard) {
      const prior = heard.findIndex((entry) => entry.id === note.entry.id);
      if (prior >= 0) heard[prior] = note.entry;
      else heard.push(note.entry);
      if (heard.length > heardSincePageLimit) heard.splice(0, heard.length - heardSincePageLimit);
    }
    // Catch-up can repeat an id with newer contents. Replace the held copy in place.
    const held = this.entries.value.findIndex((entry) => entry.id === note.entry.id);
    if (held >= 0) {
      const entries = [...this.entries.value];
      entries[held] = note.entry;
      this.refold(entries);
      return;
    }
    this.entryIDs.add(note.entry.id);
    this.display.add(note.entry);
    const entries = [...this.entries.value, note.entry];
    batch(() => {
      this.artifacts.value = withArtifactsOf(this.artifacts.value, note.entry);
      if (this.isFollowingEnd && entries.length > this.nextTrimAt) return this.trimFront(entries);
      this.entries.value = entries;
      this.items.value = this.display.items;
    });
  },
  /**
   * The oldest entries let go, down to `entriesKept`, while the chat follows the end (the
   * window's trimFront). Cut where a row begins, so every row left is the row it was; what went
   * is only marked as there, and reaching the top pages it back in as any earlier page comes.
   */
  trimFront(this: Work, entries: TranscriptEntry[]): void {
    const items = this.display.items;
    const position = new Map<string, number>();
    entries.forEach((entry, index) => { if (!position.has(entry.id)) position.set(entry.id, index); });
    const starts = items.flatMap((item) => position.get(item.id) ?? []);
    const latest = starts.length > itemsKept ? starts[starts.length - itemsKept]! : 0;
    const wanted = starts.find((start) => start >= entries.length - entriesKept) ?? latest;
    const cut = Math.min(wanted, latest);
    if (cut > 0) {
      this.keepLeadAsk(entries.slice(0, cut), entries.slice(cut));
      entries = entries.slice(cut);
      this.firstEntryIndex.value += cut;
      this.hasMoreBefore.value = true;
      this.refold(entries);
    } else {
      this.items.value = items;
    }
    // Few rows can fold thousands of entries, a long turn's tool updates (#214): the oldest go
    // even so. The rows already folded from them stay as drawn, and reaching the top pages them
    // back in, so a row is only ever folded again from all of its entries.
    if (entries.length > entriesTrimmedAt) {
      const drop = entries.length - entriesKept;
      for (let i = 0; i < drop; i++) this.entryIDs.delete(entries[i]!.id);
      this.keepLeadAsk(entries.slice(0, drop), entries.slice(drop));
      entries = entries.slice(drop);
      this.firstEntryIndex.value += drop;
      this.hasMoreBefore.value = true;
      const artifacts = this.artifacts.value;
      if (artifacts.some((artifact) => !this.entryIDs.has(artifact.entryID))) {
        this.artifacts.value = artifacts.filter((artifact) => this.entryIDs.has(artifact.entryID));
      }
    }
    this.entries.value = entries;
    this.nextTrimAt = Math.max(entriesTrimmedAt, entries.length + entriesTrimmedAt - entriesKept);
  },
  /** The prompt of the turn `kept` starts in, from what goes before it, unless `kept` starts with one (#3249). */
  keepLeadAsk(this: Work, dropped: readonly TranscriptEntry[], kept: readonly TranscriptEntry[]): void {
    if (kept[0] && isAskEntry(kept[0])) { this.leadAsk = null; return; }
    for (let i = dropped.length - 1; i >= 0; i--) {
      if (isAskEntry(dropped[i]!)) { this.leadAsk = dropped[i]!; return; }
    }
  },
  /**
   * The chat says whether it follows the end. Back at the end, the finished turns above the
   * entries are let go down to `turnsKept`: a long scroll up holds no more than it read (#170).
   */
  setFollowingEnd(this: Work, following: boolean): void {
    this.isFollowingEnd = following;
    const held = this.turns.value;
    if (!following || held.length <= turnsKept + openingTurns) return;
    const cut = held.length - turnsKept;
    batch(() => {
      if (this.firstPrompt.value !== null) this.firstPrompt.value += personPrompts(held.slice(0, cut));
      this.turns.value = held.slice(cut);
      this.firstTurn.value += cut;
    });
  },
  /** The finished turns at the end of the conversation, and where the one in progress starts. */
  replaceTurns(this: Work, page: TurnsPage): void {
    batch(() => {
      this.turns.value = keepingLatestByID(page.turns);
      this.firstTurn.value = page.firstTurn;
      this.firstPrompt.value = page.firstPrompt ?? null;
      this.openTurnStart.value = page.openStart;
    });
  },
  /** Earlier finished turns, put in front. Past the cap, they wait until the reader is back at the end (#291). */
  prependTurns(this: Work, page: TurnsPage): void {
    if (this.turns.value.length >= historyTurnsCap) return;
    batch(() => {
      this.turns.value = keepingLatestByID([...page.turns, ...this.turns.value]);
      this.firstTurn.value = page.firstTurn;
      this.firstPrompt.value = page.firstPrompt ?? null;
    });
  },
  /**
   * The first page of the conversation, with what was heard and is not on it laid after it.
   * `ask` is the open turn's prompt, read on its own when the page starts after it (#3249).
   */
  replaceTranscript(this: Work, page: TranscriptPage, ask?: TranscriptEntry): void {
    const entries = keepingLatestByID([...page.entries, ...(this.heardSincePage ?? [])]);
    this.heardSincePage = null;
    this.transcriptEnd = page.total;
    this.leadAsk = page.firstIndex > this.openTurnStart.value && ask && isAskEntry(ask) ? ask : null;
    batch(() => {
      this.firstEntryIndex.value = page.firstIndex;
      this.hasMoreBefore.value = page.firstIndex > this.openTurnStart.value;
      this.transcriptLoadFailure.value = null;
      this.transcriptSource.value = "host";
      this.refold(entries);
    });
  },
  /**
   * This device's copy of a chat (#4790), drawn while its host's page is on its way: never over
   * a page the host gave. What is heard meanwhile is laid after it, and kept for the page.
   */
  drawTranscriptCopy(this: Work, copy: TranscriptCopy): void {
    const watching = this.watching.value;
    if (watching?.host !== copy.host || watching.session !== copy.session || this.transcriptSource.value !== "none") return;
    batch(() => {
      this.replaceTurns(copy.turns);
      this.firstEntryIndex.value = copy.page.firstIndex;
      // Earlier pages wait for the host's answer.
      this.hasMoreBefore.value = false;
      this.transcriptSource.value = "device";
      this.transcriptEnd = copy.page.total;
      // A load that failed before the copy was read said nothing was on show; now something is.
      if (this.transcriptLoadFailure.value?.nothingLoaded) this.transcriptLoadFailure.value = null;
      this.refold(keepingLatestByID([...copy.page.entries, ...this.entries.value]));
    });
  },
  /**
   * This device's copy of the machines (#4790), drawn before the control plane answers: only
   * on a page that holds none yet. Each host stays marked until it answers.
   */
  drawCopy(this: Work, machines: readonly MachineCopy[]): void {
    if (machines.length === 0 || this.hosts.value.length > 0) return;
    batch(() => {
      this.takeHosts(machines.map((m) => m.host));
      this.folders.value = { ...this.folders.value, ...Object.fromEntries(machines.filter((m) => m.folders).map((m) => [m.host.id, m.folders!])) };
      for (const m of machines) {
        this.replaceAgents(m.agents, m.host.id);
        // The host's first catch-up asks only for what changed since the copy (#4794).
        if (m.point) this.listPoints.set(m.host.id, m.point);
      }
      for (const m of machines) this.copyReads.set(m.host.id, m.at);
      this.fromDevice.value = new Set(machines.map((m) => m.host.id));
    });
  },
  /** A host answered for itself: no longer from this device. */
  answered(this: Work, host: string): void {
    if (!this.fromDevice.value.has(host)) return;
    const left = new Set(this.fromDevice.value);
    left.delete(host);
    this.fromDevice.value = left;
  },
  /** An earlier page, put in front of what is held. Past the cap, it waits (#291). */
  prepend(this: Work, page: TranscriptPage): void {
    if (this.entries.value.length >= historyEntriesCap) return;
    const entries = [...page.entries.filter((e) => !this.entryIDs.has(e.id)), ...this.entries.value];
    batch(() => {
      this.firstEntryIndex.value = page.firstIndex;
      this.hasMoreBefore.value = page.firstIndex > this.openTurnStart.value;
      this.refold(entries);
    });
  },
  clearTranscript(this: Work): void {
    // A chat chosen is a page on its way.
    this.heardSincePage = [];
    this.transcriptEnd = null;
    this.transcriptLoadFailure.value = null;
    this.transcriptSource.value = "none";
    this.firstEntryIndex.value = 0;
    this.hasMoreBefore.value = false;
    this.turns.value = [];
    this.firstTurn.value = 0;
    this.firstPrompt.value = null;
    this.openTurnStart.value = 0;
    this.leadAsk = null;
    this.refold([]);
  },
  refold(this: Work, entries: TranscriptEntry[]): void {
    this.entryIDs = new Set(entries.map((e) => e.id));
    this.display = new DisplayBuilder();
    // Paged back in, the prompt is drawn from among the entries.
    if (this.leadAsk && this.entryIDs.has(this.leadAsk.id)) this.leadAsk = null;
    if (this.leadAsk) this.display.add(this.leadAsk);
    for (const entry of entries) this.display.add(entry);
    this.entries.value = entries;
    this.items.value = this.display.items;
    this.artifacts.value = artifactsIn(entries);
    this.nextTrimAt = entriesTrimmedAt;
  },
  /** Whether a host can do what `capability` names (#1748): true when it said no list. */
  has(this: Work, host: string, capability: string): boolean {
    return hostHas(this.hosts.value, host, capability);
  },
};

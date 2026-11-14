// Part of the Store (#5384): chatLoading.
import { batch } from "@preact/signals";
import type { UUID, FindResult } from "../../protocol/generated";
import { Failure } from "../../protocol/generated";
import { CallFailed } from "../../wire/link";
import { describe, methodNotFound } from "../errors";
import { log } from "../../log";
import { folderPath as agentFolderPath } from "../groups";
import { sessionRef as copyRef, type TranscriptCopy } from "../localCopy";
import { mark } from "../marks";
import type { Store } from "../store";
import { openingTurns, turnPage, prefetchKept, prefetchFresh, neighbours, historyEntriesCap, historyTurnsCap, type TurnDetailPage } from "./shared";

export const chatLoadingMethods = {
  async openSession(this: Store, host: string, session: string): Promise<void> {
    this.watch(host, session);
    // What was fetched for it under the pointer or beside the last one opened, at once (#4795).
    const fetched = this.takePrefetched(host, session);
    if (fetched) this.drawTranscriptCopy(fetched);
    await this.loadTranscript(host, session);
    // The rows either side, which are opened next.
    const now = this.watching.value;
    if (now?.host === host && now.session === session) this.prefetchNeighbours(host, session);
  },
  /**
   * Fetches a chat before it is opened (#4795; spec 4777-fast): the row under the pointer, and the
   * rows beside the open one. Not the open one, nor one held and fresh; a fetch that fails holds nothing.
   */
  async prefetch(this: Store, host: string, session: string): Promise<void> {
    const key = `${host}|${session}`;
    const now = this.watching.value;
    if (now?.host === host && now.session === session) return;
    const held = this.prefetched.get(key);
    if (held && Date.now() - held.at < prefetchFresh) return;
    if (this.prefetching.has(key)) return;
    this.prefetching.add(key);
    try {
      const agentID = session as never;
      const turns = await this.link.call("agents/turns", { agentID, limit: openingTurns }, host);
      const page = await this.link.call("agents/transcript", { agentID, limit: turnPage, from: turns.openStart }, host);
      this.prefetched.delete(key);
      this.prefetched.set(key, { kind: "transcript", ref: copyRef(session), host, session, turns, page, at: Date.now() });
      while (this.prefetched.size > prefetchKept) this.prefetched.delete(this.prefetched.keys().next().value!);
    } catch {
      // Nothing held: opening it loads as before.
    } finally {
      this.prefetching.delete(key);
    }
  },
  /** What was fetched for a chat, when it is fresh: taken, so it is drawn once. */
  takePrefetched(this: Store, host: string, session: string): TranscriptCopy | undefined {
    const key = `${host}|${session}`;
    const held = this.prefetched.get(key);
    this.prefetched.delete(key);
    return held && Date.now() - held.at < prefetchFresh ? held : undefined;
  },
  /** The live sessions of the open one's folder, in the order its list draws them, either side of it. */
  prefetchNeighbours(this: Store, host: string, session: string): void {
    const agent = this.agents.value[host]?.find((a) => a.id === session);
    if (!agent) return;
    const list = this.folderView(host, agentFolderPath(agent)).headings.flatMap((h) => h.agents.map((a) => a.id));
    for (const id of neighbours(session, list)) void this.prefetch(host, id);
  },
  closeSession(this: Store): void {
    this.unwatch();
  },
  /** The open session's record whole, with the menus a lean list leaves out (#107). Whether its host answered. */
  async loadWhole(this: Store, host: string, session: string): Promise<boolean> {
    const listed = await this.link.call("agents/list", {
      includeArchived: true, archivedCommands: true, archivedOnly: false, lean: false, agentID: session as never, limit: 1,
    }, host).catch(() => null);
    // A host from before #107 ignores agentID and answers with its newest, which isn't this one.
    const whole = listed?.find((a) => a.id === session);
    if (whole) this.addAgents([whole], host);
    return listed !== null;
  },
  /**
   * The open session's record and its history, side by side. Looked for once its host has answered both,
   * so one not in hand then has gone (#2652); a call that failed is not an answer, and the chat says it
   * with Try Again instead of calling the session deleted (#2743). Only the history is waited for.
   */
  async loadTranscript(this: Store, host: string, session: string): Promise<void> {
    mark("open-session");
    const page = this.loadPage(host, session).then((shown) => {
      if (shown) mark("session-open", "open-session");
      return shown;
    });
    void Promise.all([this.loadWhole(host, session), page]).then(([listed, paged]) => {
      const now = this.watching.value;
      if (listed && paged && now?.host === host && now.session === session) this.lookedFor.value = { host, session };
    }, () => {});
    await page;
  },
  /**
   * The finished turns first, as summaries, then the transcript from where the open turn starts. Whether
   * its host answered: with the page, or that it has no such session (#2743).
   */
  async loadPage(this: Store, host: string, session: string): Promise<boolean> {
    // Only what is heard from now: what came before is on the page or before it, and laid after a
    // page that starts in a turn's reply it drew the turn's ask below that reply (#2807).
    this.heardSincePage = [];
    const load = ++this.transcriptLoads;
    const agentID = session as never;
    const current = () => {
      const now = this.watching.value;
      return now?.host === host && now.session === session && load === this.transcriptLoads;
    };
    // Nothing held: this device's copy first, read from IndexedDB, so the chat can resume from it (#4794).
    if (this.chatEnd() === null && this.readCopy) {
      const copy = await this.readCopy(session).catch(() => undefined);
      if (copy && current()) this.drawTranscriptCopy(copy);
    }
    // What was written since the end held (#4794), one page from it, in place of the whole opening;
    // a page that leaves a gap, or no answer, opens it whole.
    const end = this.chatEnd();
    if (end !== null) {
      const resumed = await this.link.call("agents/transcript", { agentID, limit: turnPage, from: end }, host).catch(() => null);
      if (!current()) return false;
      if (resumed && this.takeResumed(resumed)) return true;
    }
    // The last 12, as the window opens a chat (#90); the rest come as the top is reached. A host
    // too old to keep turns gives the lot; any other failure is said, and the chat still opens (#400).
    const failed: { turns?: string; page?: string } = {};
    const turns = await this.link.call("agents/turns", { agentID, limit: openingTurns }, host)
      .catch((error: unknown) => {
        if (!(error instanceof CallFailed && error.code === methodNotFound)) failed.turns = describe(error);
        return { turns: [], firstTurn: 0, openStart: 0 };
      });
    let gone = false;
    const page = await this.link.call("agents/transcript", { agentID, limit: 200, from: turns.openStart }, host)
      .catch((error: unknown) => {
        gone = error instanceof CallFailed && error.code === Failure.noSuchAgent;
        failed.page = describe(error);
        log("call.failed", error instanceof CallFailed ? error.code : undefined);
        return null;
      });
    // A chat opened since is not this one, and a newer load of this one has the say.
    const now = this.watching.value;
    if (now?.host !== host || now.session !== session || load !== this.transcriptLoads) return false;
    if (!page) {
      // This device's copy stays on show until the host answers (#4790).
      if (this.transcriptSource.value === "device") return gone;
      this.transcriptLoadFailure.value = { nothingLoaded: true, reason: failed.page ?? "no answer." };
      return gone;
    }
    // A long open turn's page starts after its prompt: the prompt is read on its own (#3249).
    const ask = page.firstIndex > turns.openStart
      ? (await this.link.call("agents/transcript", { agentID, before: turns.openStart + 1, limit: 1, from: turns.openStart }, host)
        .catch(() => null))?.entries[0]
      : undefined;
    const still = this.watching.value;
    if (still?.host !== host || still.session !== session || load !== this.transcriptLoads) return false;
    batch(() => {
      this.replaceTurns(turns);
      this.replaceTranscript(page, ask);
      if (failed.turns) this.transcriptLoadFailure.value = { nothingLoaded: false, reason: failed.turns };
    });
    return true;
  },
  /** Ask again for the open chat's history, after it did not load (#400). */
  async reloadTranscript(this: Store): Promise<void> {
    const watching = this.watching.value;
    if (watching) await this.loadTranscript(watching.host, watching.session);
  },
  /** Find in Chat (#1532): what was said in the open chat that holds `text`, found by its host. */
  async find(this: Store, host: string, agentID: string, text: string): Promise<FindResult | null> {
    return this.link.call("agents/find", { agentID: agentID as UUID, text }, host).catch(() => null);
  },
  /** Whether the transcript entry at `index` is in hand: in the page, or in a stored turn (AgentsModel.holds). */
  holds(this: Store, index: number): boolean {
    return (this.entries.value.length > 0 && index >= this.firstEntryIndex.value)
      || this.turns.value.some((turn) => turn.start <= index && index < turn.end);
  },
  /** Earlier pages, as Load Earlier brings them, until the entry at `index` is in hand or no more come (#1532). */
  async loadUntil(this: Store, index: number): Promise<void> {
    while (!this.holds(index) && this.hasMoreOfTheConversation) {
      const before = [this.firstTurn.value, this.firstEntryIndex.value, this.turns.value.length, this.entries.value.length].join();
      await this.loadEarlier();
      if ([this.firstTurn.value, this.firstEntryIndex.value, this.turns.value.length, this.entries.value.length].join() === before) return;
    }
  },
  /** Further back: the open turn's earlier entries, then the turns before it. A chat scrolled up
   * stops once it holds a bounded history (#291). */
  async loadEarlier(this: Store): Promise<void> {
    const watching = this.watching.value;
    if (!watching || !this.hasMoreOfTheConversation) return;
    const agentID = watching.session as never;
    if (!this.hasMoreBefore.value) {
      if (this.turns.value.length >= historyTurnsCap) return;
      const turns = await this.link.call("agents/turns", { agentID, before: this.firstTurn.value, limit: 50 }, watching.host)
        .catch(() => null);
      if (turns && this.watching.value === watching) this.prependTurns(turns);
      return;
    }
    if (this.entries.value.length >= historyEntriesCap) return;
    const page = await this.link.call("agents/transcript", {
      agentID, before: this.firstEntryIndex.value, limit: 200, from: this.openTurnStart.value,
    }, watching.host).catch(() => null);
    if (page && this.watching.value === watching) this.prepend(page);
  },
  /**
   * One page of a finished turn, the last `turnPage` entries before `range.end` (#291).
   * `firstIndex` is past `range.start` when the turn has earlier steps.
   */
  async turnEntries(this: Store, host: string, session: string, range: { start: number; end: number }): Promise<TurnDetailPage> {
    const span = range.end - range.start;
    if (span <= 0) return { entries: [], firstIndex: range.start };
    const page = await this.link.call("agents/transcript", {
      agentID: session as never, before: range.end, limit: Math.min(span, turnPage), from: range.start,
    }, host).catch(() => null);
    if (!page) return { entries: [], firstIndex: range.start, failed: true };
    return { entries: page.entries, firstIndex: page.firstIndex };
  },
};

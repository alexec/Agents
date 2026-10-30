// The chosen session's chat (071 US2, FR-023): concise turns at the chosen level (069), tool
// calls, plans and background tasks (057), live from agent/entry and agent/changed; the cards
// at the end, with the agent's wait on events under them (#1995); the prompt pinned to the foot at every width (US6 scenario 4), with where
// the session works, its labels and its runtime over it, as in the window (#108). Long
// conversations come a page at a time as the top is reached, and the pane follows the end
// unless the person has scrolled up.
import { Fragment } from "preact";
import { useSignal } from "@preact/signals";
import { useEffect, useLayoutEffect, useMemo, useRef } from "preact/hooks";
import { openTurnsHeld, rememberOpen, type Store } from "../model/store";
import { backgroundAge, backgroundEnded, backgroundNoun, isRunning, subagentNoSteps, subagentStatus } from "../model/background";
import { display, isPersonsAsk, isWorking, type ChatTurn, type Item } from "../model/turns";
import { fromWireDate, toWireDate } from "../protocol/dates";
import type { Agent, AppViewCall, BackgroundItem, ClientPermissionSettings, FileMentionDTO, FindMatch, FindResult, TranscriptEntry, TurnSummary } from "../protocol/generated";
import { replace, route } from "../route";
import { useWaitingCards, type WaitingCard } from "./Cards";
import { OfflineStrip } from "./OfflineStrip";
import { DiskStrip } from "./DiskStrip";
import { KeptBubbles } from "./Kept";
import { FolderGoneNotice, MissingFolderStrip } from "./MissingFolder";
import { AccountMoveStrip } from "./AccountMove";
import { ContinueStrip } from "./ContinueStrip";
import { CurrentPlanStrip } from "./PlanStrip";
import { GoalCard } from "./GoalCard";
import { Telling } from "./Telling";
import { Labels } from "./Labels";
import { Prompt } from "./Prompt";
import { PromptMenus } from "./PromptMenus";
import { ContextMeter, CostLimitBanner, SandboxCapsule } from "./PromptStatus";
import { branchFromPrompt, RenameInput, SessionButtons, SessionMenu } from "./SessionMenu";
import { Beacon } from "./SessionRow";
import { drawable } from "../model/options";
import { quietLine } from "../model/activity";
import { cardTitle, carryOnHelp, carryOnPrompt, openBlock } from "../model/block";
import { sentPrompts } from "../model/promptHistory";
import { sessionPrompts } from "../model/sessionPrompts";
import { PromptList } from "./chat/PromptList";
import { asksToArchive, folderPath } from "../model/groups";
import { CallActionsContext, fromLine, ItemRow, TurnView, type CallActions } from "./chat/Rows";
import { Modal } from "./Modal";
import { nameOf, pathOf, setPane } from "./files/paneState";
import { FileSearch, isOpenFileKey } from "./files/FileSearch";
import { focusedEntry, focusedIndex } from "../model/focus";
import { ViewLayerContext } from "./chat/AppView";
import { recipient, type Start, viewPin } from "./chat/appViewBridge";
import { ViewLayer, type ViewActions } from "./chat/viewLayer";
import { ViewDiff } from "./chat/ViewDiff";
import { offerStart } from "./NewAgent";
import { BackToList } from "./BackToList";
import { comingBackDescription, footStatusWords } from "../model/status";
import { ArchiveCard } from "./ArchiveCard";
import { showsThoughts, shownItems } from "../model/thoughts";
import { hasTurnInFlight, promptPlaceholder, willQueue } from "../model/promptWords";
import { eventWaitLine, eventWaitMinutes, eventWaitSummaryLines, leaseMark, lineResource } from "../model/rowLines";
import { routeHash } from "../route";
import { sessionRuntimeName } from "../model/runtimes";
import { GuardedChangeCard } from "./GuardedChange";
import { Capability } from "../protocol/capabilities.generated";
import { hostNeedsUpdate } from "../model/capabilities";
import { WorkingMark } from "./SessionRow";
import { runningTool } from "../model/sidebar";
import { composerReason } from "../model/orgPolicy";
import { autoHeader, cellOf } from "../model/levels";

/** One opened turn's entries, so an earlier page can be put in front and drawn again (#291). */
interface HeldTurn {
  entries: TranscriptEntry[];
  items: Item[];
  hasEarlier: boolean;
  firstIndex: number;
}

/** A turn's lines, without the ask the turn already shows above its steps. */
function shown(entries: TranscriptEntry[]): Item[] {
  const items = display(entries);
  return items[0] && isPersonsAsk(items[0]) ? items.slice(1) : items;
}


/** How close to the end counts as being back at it, on the way down (#378). */
const atTheEnd = 40;

/** Whether a key pressed with focus here is the transcript's to take: not while something else takes keys (#378). */
function takesKeys(target: EventTarget | null): boolean {
  return target instanceof HTMLElement && !!target.closest("input, textarea, select, [contenteditable], dialog, [role=menu], [role=listbox]");
}

export function Chat({ store, host, session, down: linkDown }: { store: Store; host: string; session: string; down: boolean }) {
  // An offline host is the link down for this chat alone: read what was last heard, send nothing.
  const hostDown = !linkDown && !store.hostIsOnline(host);
  const down = linkDown || hostDown;
  // A stopped workspace that starts when used still takes a prompt, kept until it is up (#691 US3).
  const keeps = hostDown && store.startsWhenUsed(host);
  // Why nothing can be sent to this host now, in its organisation's words (#998): the kill switch, or no policy.
  const refusedHere = composerReason(store.policyStates.value[host]);
  const r = route.value;
  const agent = store.agent(host, session);
  // Opened: its runtime starts now, so the reply does not wait for it (#183). Once it has been
  // on screen a moment (the window's PrewarmRequest.openedAfter), so paging past chats starts
  // nothing (#202).
  useEffect(() => {
    const timer = setTimeout(() => store.prewarm(host, session, "opened"), 1500);
    return () => clearTimeout(timer);
  }, [host, session]);
  // One search per session, so the prompt's file search is not started afresh on every render.
  const findFiles = useMemo(() => (term: string) => store.mentions(host, session, term), [host, session]);
  // Open File… (#415): ⌘P or Ctrl+P, wherever the keys are, opens the search over the chat.
  const searchingFiles = useSignal(false);
  useEffect(() => {
    searchingFiles.value = false;
    const press = (e: KeyboardEvent) => {
      if (e.defaultPrevented || e.isComposing || !isOpenFileKey(e)) return;
      e.preventDefault();
      if (store.agent(host, session)) searchingFiles.value = true;
    };
    document.addEventListener("keydown", press);
    return () => document.removeEventListener("keydown", press);
  }, [host, session]);
  const openFound = (file: FileMentionDTO) => {
    searchingFiles.value = false;
    // Markdown on its live page, anything else as source to type in, under Files.
    setPane(session, { tab: "files", file: file.path, fileLine: undefined, last: file.path });
    if (!route.peek().files) replace({ ...route.peek(), files: true });
  };
  /** The run of calls gone to from elsewhere: opened, with its first call (#1315). */
  const focusedRun = useSignal<string | null>(null);
  /** Find in Chat is up over the chat (#1532). */
  const finding = useSignal(false);
  // ⌘F (Ctrl+F) finds in the open chat, as in the window (#1532), in place of the browser's own find.
  useEffect(() => {
    const press = (e: KeyboardEvent) => {
      if (e.key.toLowerCase() !== "f" || !(e.metaKey || e.ctrlKey) || e.shiftKey || e.altKey) return;
      // A host too old to find leaves ⌘F to the browser (#1748).
      if (!store.has(host, Capability.agentsFind1)) return;
      e.preventDefault();
      finding.value = true;
    };
    document.addEventListener("keydown", press);
    return () => document.removeEventListener("keydown", press);
  }, [host]);
  /** The Prompts list is up over the chat (#1658). */
  const listingPrompts = useSignal(false);
  useEffect(() => {
    finding.value = false;
    listingPrompts.value = false;
  }, [host, session]);
  /** The few opened turns whose entries are held, newest last (#291). */
  const fetched = useSignal<Record<string, HeldTurn>>({});
  /** Turns whose steps were asked for and did not come, until asked again (#544). */
  const failedTurns = useSignal<Record<string, true>>({});
  /** The subagent whose steps are open over the chat, as the phone's sheet (#544). */
  const subagent = useSignal<BackgroundItem | null>(null);
  const openedTurns = useRef<string[]>([]);
  const earlierTurn = useRef<string | null>(null);
  /** The stored turn Find asked the steps of, so a miss is not asked again on every draw (#1532). */
  const findAsked = useRef<string | null>(null);
  /** Which chat a turn's page was asked for, so a reply for one left behind is dropped. */
  const watchingSession = useRef(`${host}|${session}`);
  watchingSession.current = `${host}|${session}`;

  // Each turn the same object until an entry lands in it, so only that one is drawn again (#170).
  const rows: ChatTurn[] = store.chatTurns.value;
  // What a call's line asks of the background is only whether its call still runs: the list
  // changes when that does, and not with every other change to the agent.
  const allBackground = agent?.background;
  const runningCalls = (allBackground ?? []).filter(isRunning).map((item) => item.toolCallID ?? "").join(" ");
  const background = useMemo(() => (allBackground ?? []).filter(isRunning), [runningCalls]);
  const live = agent ? isWorking(agent.state) : false;
  const failure = store.transcriptLoadFailure.value;

  // What an open call's links do here (the window's ChatActions): a file it touched opens in the
  // Files pane at the line it named, as the Remote's does, and an edit opens under Changes.
  const callActions = useMemo<CallActions>(() => {
    const showPane = () => { if (!route.peek().files) replace({ ...route.peek(), files: true }); };
    return {
      open: (location) => {
        setPane(session, { tab: "files", file: location.path, fileLine: location.line, last: location.path });
        showPane();
      },
      showEdit: (diff) => {
        setPane(session, { tab: "changes", changed: diff.path });
        showPane();
      },
      // Into this chat's prompt bar, after what is typed there (#1553).
      quote: (words) => { store.offeredQuote.value = { draftKey: `${host}|${session}`, words }; },
      // Branch from Here on the person's prompt (#1658): never on an archived session, as Branch,
      // nor on a host too old to branch (#1748).
      branchFrom: agent && agent.state !== "archived" && !down && store.has(host, Capability.chatBranch1) ? (entryID, text) => {
        const now = store.agent(host, session);
        if (now) void branchFromPrompt(store, host, now, entryID, text);
      } : undefined,
      // On a host too old to branch, Branch from Here stays, greyed, and says so (#1866).
      branchNeedsUpdate: !!agent && agent.state !== "archived" && !store.has(host, Capability.chatBranch1),
      // Answered only while the agent waits on it, and while its host answers (#253).
      waitingSandbox: agent?.pendingSandboxFailure,
      sandboxSetBy: store.sandboxSetBy.value[host],
      answerSandbox: agent?.pendingSandboxFailure && !down ? (carryOn) => store.answerSandbox(host, session, carryOn) : undefined,
      subagentSteps: (item) => (subagent.value = item),
      // A card opens its file as the agent's call did: the same path as `agent/showFile` (#836).
      showFile: (file) => {
        store.noteChartHint(host, file.path, file.chart);
        store.shownFile.value = { host, agentID: session, path: file.path, line: file.line, at: Date.now() };
      },
      noteChart: (file) => store.noteChartHint(host, file.path, file.chart),
      readFile: (path) => store.readFile(host, session, path),
    };
  }, [host, session, agent?.pendingSandboxFailure, down, !agent || agent.state === "archived", store.has(host, Capability.chatBranch1)]);

  const scroller = useRef<HTMLDivElement>(null);
  const chatColumn = useRef<HTMLElement>(null);
  // The chat's views (#187): one layer while the chat is open, its views told and taken down
  // when another chat opens, and when the page leaves the chat.
  const layer = useMemo(() => new ViewLayer(), []);
  const pinFolder = agent ? folderPath(agent) : undefined;
  const viewHosting = useMemo(() => {
    const actions: ViewActions = {
      agentID: session,
      call: (method, params) => store.link.call(method, params as never, host) as Promise<unknown>,
      send: (text) => store.prompt(host, session, text, []),
      // Pin (#189): under the folder the chat works in.
      ...(pinFolder ? { pin: (call: AppViewCall) => store.pinView(host, pinFolder, viewPin(call)) } : {}),
      // A new agent, filled in by the view (#834): the form in the chat's folder.
      ...(pinFolder ? { startAgent: (start: Start) => offerStart(store, host, pinFolder, start) } : {}),
      // The session on a pull request's branch (#837), asked under the view first.
      ...(pinFolder ? { recipient: (message) => recipient(store.agents.value[host] ?? [], message, pinFolder) } : {}),
      sendTo: (id, text) => store.prompt(host, id, text, []),
    };
    return { layer, actions };
  }, [layer, host, session, pinFolder]);
  useEffect(() => () => { void layer.tearDownAll("The conversation was closed."); }, [layer, host, session]);
  useEffect(() => () => layer.stop(), [layer]);
  // A view read when the link dropped may never be answered: read it again (#978).
  useEffect(() => {
    const off = store.link.onState((state) => { if (state.kind === "open") layer.reconnected(); });
    return () => { off(); };
  }, [layer, store]);
  useLayoutEffect(() => {
    layer.scroller = scroller.current;
    layer.chat = chatColumn.current;
    layer.sync();
  });
  const following = useRef(true);
  /** Following the end or not, told to the store: it trims the chat's front only while following. */
  // Away from the end, where Jump to end is shown whether or not anything new has come (#252).
  const away = useSignal(false);
  const follow = (on: boolean) => {
    if (following.current === on) return;
    following.current = on;
    away.value = !on;
    store.setFollowingEnd(on);
  };
  const loadingEarlier = useRef(false);
  const settled = useRef(false);
  /** The last scroll seen, to tell a move up the page from the page growing or being trimmed (#378). */
  const lastScroll = useRef({ top: 0, height: 0 });
  useEffect(() => {
    // Whether its runtime takes words mid-turn, or pictures, is known once it has run.
    void store.loadRuntimes(host);
    focusedRun.value = null;
    fetched.value = {};
    failedTurns.value = {};
    subagent.value = null;
    openedTurns.current = [];
    settled.current = false;
    const timer = setTimeout(() => (settled.current = true), 400);
    return () => clearTimeout(timer);
  }, [session]);
  // A chat opens following its end, before the layout effects below: a line asked for as it
  // opens (a notice's, from its notification, #2860) then leaves the end, and stays left.
  useLayoutEffect(() => {
    following.current = true;
    away.value = false;
    store.setFollowingEnd(true);
  }, [session]);

  // Following the end: every kind of growth, a new line or a longer one, keeps the foot in view.
  const entryCount = store.entries.value.length;
  useLayoutEffect(() => {
    const el = scroller.current;
    if (!el) return;
    if (following.current) { if (!loadingEarlier.current) el.scrollTop = el.scrollHeight; }
    // Reading: rows put in above (an earlier page) keep the turn held where it was, before the
    // page is painted (#2310).
    else keepHeld(el);
  }, [entryCount, store.turns.value.length, session]);
  // Every row is watched, those drawn since too: a queued bubble or a card that grows without an
  // entry arriving used to leave the foot a frame or more behind (#378).
  const sizes = useRef<ResizeObserver | null>(null);
  useLayoutEffect(() => {
    const el = scroller.current;
    if (!el) return;
    const watcher = new ResizeObserver(() => {
      if (following.current) { if (!loadingEarlier.current) el.scrollTop = el.scrollHeight; return; }
      // Reading back: a turn above that grew (its steps came, a picture, code colour) moves
      // the turn held back to where it was on screen, in every browser, Safari before 27
      // too, which has no scroll anchoring of its own (#2310). An earlier page too, before it
      // is painted.
      keepHeld(el);
    });
    sizes.current = watcher;
    watcher.observe(el);
    return () => { watcher.disconnect(); sizes.current = null; };
  }, []);
  useLayoutEffect(() => {
    const el = scroller.current;
    if (el && sizes.current) for (const child of Array.from(el.children)) sizes.current.observe(child);
  });

  /** The turn a reader's place is held by, and how far down the pane it starts (#2310). */
  const held = useRef<{ id: string; top: number } | null>(null);
  const turnTop = (el: HTMLElement, turn: HTMLElement) => turn.getBoundingClientRect().top - el.getBoundingClientRect().top;
  /** Holds the place by the first turn that starts on screen, or the one the top of the pane is in. */
  const holdTurn = (el: HTMLElement) => {
    const turns = Array.from(el.querySelectorAll<HTMLElement>("article.turn"));
    const shown = turns.filter((turn) => turnTop(el, turn) + turn.offsetHeight > 0);
    const turn = shown.find((t) => turnTop(el, t) >= -0.5) ?? shown[0];
    held.current = turn ? { id: turn.dataset.turn ?? "", top: turnTop(el, turn) } : null;
  };
  /** Puts the turn held back where it was on the pane. */
  const keepHeld = (el: HTMLElement) => {
    const was = held.current;
    if (!was) return;
    const turn = el.querySelector<HTMLElement>(`article.turn[data-turn="${CSS.escape(was.id)}"]`);
    if (!turn) return;
    const by = turnTop(el, turn) - was.top;
    if (Math.abs(by) > 0.5) el.scrollTop += by;
  };
  // A wheel or a finger up the pane is reading back, even in the frame the page grows (#2310):
  // the scroll test below cannot tell those apart.
  const fingerAt = useRef<number | null>(null);
  const readBack = () => {
    const el = scroller.current;
    if (!el || !following.current || el.scrollHeight <= el.clientHeight + 1) return;
    holdTurn(el);
    follow(false);
  };
  const onWheel = (event: WheelEvent) => { if (event.deltaY < 0) readBack(); };
  const onTouchStart = (event: TouchEvent) => { fingerAt.current = event.touches[0]?.clientY ?? null; };
  const onTouchMove = (event: TouchEvent) => {
    const y = event.touches[0]?.clientY;
    if (fingerAt.current !== null && y !== undefined && y > fingerAt.current + 4) readBack();
  };

  const earlier = async () => {
    const el = scroller.current;
    if (!el || loadingEarlier.current || !settled.current || !store.hasMoreOfTheConversation) return;
    loadingEarlier.current = true;
    // Hold the line being read: what arrives goes above it. Following, the foot; reading, the
    // turn held, as any growth above it is (#2310).
    const fromBottom = el.scrollHeight - el.scrollTop;
    if (!following.current) holdTurn(el);
    await store.loadEarlier();
    requestAnimationFrame(() => {
      if (following.current) el.scrollTop = el.scrollHeight - fromBottom;
      else keepHeld(el);
      setTimeout(() => (loadingEarlier.current = false), 250);
    });
  };

  const onScroll = (event: Event) => {
    const el = event.currentTarget as HTMLDivElement;
    const fromBottom = el.scrollHeight - el.scrollTop - el.clientHeight;
    const was = lastScroll.current;
    lastScroll.current = { top: el.scrollTop, height: el.scrollHeight };
    if (!loadingEarlier.current) {
      // Any move up the page that is not the page itself changing size is the reader's: a wheel
      // tick, a key, the scroll bar or a finger. Following stops at once, however small (#378).
      // Growth and trimming change the height; this pane only ever moves itself down.
      if (el.scrollTop < was.top - 0.5 && el.scrollHeight === was.height) follow(false);
      // Back at the end on the way down, or right at it.
      else if (fromBottom < 1 || (fromBottom < atTheEnd && el.scrollTop > was.top)) follow(true);
      if (!following.current) holdTurn(el);
    }
    if (el.scrollTop < 400) void earlier();
  };

  // The keyboard reads the transcript when nothing else takes the keys: Page Up/Down, Space and
  // Shift-Space a pane at a time, Home/End and ⌘↑/⌘↓ to either end, ⌘↓ the same as Jump to end (#378).
  useEffect(() => {
    const press = (e: KeyboardEvent) => {
      const el = scroller.current;
      if (!el || e.defaultPrevented || e.isComposing || e.altKey || e.ctrlKey || takesKeys(e.target)) return;
      const page = Math.max(40, el.clientHeight - 60);
      const space = e.key === " " && !e.metaKey && !(e.target instanceof HTMLElement && e.target.closest("button, a, summary, [role=button]"));
      let by = 0;
      if (e.key === "PageUp" || (space && e.shiftKey)) by = -page;
      else if (e.key === "PageDown" || (space && !e.shiftKey)) by = page;
      else if (e.key === "Home" || (e.metaKey && e.key === "ArrowUp")) by = -el.scrollHeight;
      else if (e.key === "End" || (e.metaKey && e.key === "ArrowDown")) {
        e.preventDefault();
        toEnd();
        return;
      } else return;
      e.preventDefault();
      if (by < 0) readBack();
      el.scrollBy({ top: by, behavior: by === page || by === -page ? "smooth" : "instant" });
    };
    document.addEventListener("keydown", press);
    return () => document.removeEventListener("keydown", press);
  }, [host, session]);

  // Asked for from Exchanged. A message is drawn with its entry's id, and a run of calls with
  // its first call's, opened with that call and nothing else in the turn (#1315). Being sent to
  // one is being sent away from the end, or the pane would scroll straight back off it.
  const focus = focusedEntry.value;
  useLayoutEffect(() => {
    if (!focus) return;
    const turn = rows.find((item) => item.ask?.id === focus || item.items.some((part) => part.id === focus));
    if (turn?.items.some((part) => part.id === focus && part.kind === "run")) focusedRun.value = focus;
    const root = scroller.current;
    const mark = root && [...root.querySelectorAll("[data-entry]")].find((el) => el.getAttribute("data-entry") === focus);
    const target = mark && getComputedStyle(mark).display === "contents" ? mark.firstElementChild ?? mark : mark;
    if (target) {
      follow(false);
      target.scrollIntoView({ block: "center", behavior: "smooth" });
      // A notice's line, gone to from its notification, is lit a moment so the eye finds it (#2860).
      if (target.classList.contains("notice-line")) {
        target.classList.add("lit");
        setTimeout(() => target.classList.remove("lit"), 2000);
      }
      focusedEntry.value = null;
      focusedIndex.value = null;
      return;
    }
    // Found by Find in a stored turn's steps (#1532): the turn is opened, and its steps come.
    const index = focusedIndex.value;
    const stored = !turn && index !== null ? rows.find((item) => item.range && item.range.start <= index && index < item.range.end) : undefined;
    if (stored && !fetched.value[stored.id] && findAsked.current !== `${focus}|${stored.id}`) {
      follow(false);
      // Asked for here, once a find: a turn far up the chat does not load its own steps.
      findAsked.current = `${focus}|${stored.id}`;
      void latest.current.loadDetail(stored);
    }
  }, [focus, rows, fetched.value]);

  // What waits on the person is in the conversation, not over it (#723), after all of it (#1995),
  // and the agent's wait on events under it.
  const asked = useWaitingCards({ store, host, session, down });
  const cards: WaitingCard[] = [
    // A change its agent made to the folder's own files, asked here (#531).
    ...store.guardedChanges(host, { session }).map(({ folder, change }) => ({
      key: `guarded:${folder}|${change.path}`,
      node: <div class="cards"><GuardedChangeCard store={store} host={host} folder={folder} change={change} down={down} /></div>,
    })),
    ...asked,
    // An ask to be archived waits the same way (#827).
    ...(agent && asksToArchive(agent) ? [{
      key: `archive:${agent.id}`,
      node: <ArchiveCard store={store} host={host} agent={agent} disabled={down} />,
    }] : []),
  ];

  const toEnd = () => {
    const el = scroller.current;
    follow(true);
    if (el) el.scrollTo({ top: el.scrollHeight, behavior: "smooth" });
  };

  // The open session's row clicked again: to its latest message, as opening it is (#1349).
  const toEndAsks = store.toEndAsks.value;
  const toEndSeen = useRef(toEndAsks);
  useEffect(() => {
    if (toEndAsks === toEndSeen.current) return;
    toEndSeen.current = toEndAsks;
    toEnd();
  }, [toEndAsks]);

  useEffect(() => { void store.loadCost(host); }, [store, host]);

  const hold = (id: string, value: HeldTurn) => {
    const kept = rememberOpen(fetched.peek(), openedTurns.current, id, value);
    openedTurns.current = kept.order;
    fetched.value = kept.held;
  };

  /** The last page of a finished turn. A miss is not held, so it can be asked again. */
  const loadDetail = async (turn: ChatTurn) => {
    if (!turn.range || fetched.peek()[turn.id]) return;
    const stamp = `${host}|${session}`;
    const page = await store.turnEntries(host, session, turn.range);
    if (`${watchingSession.current}` !== stamp) return;
    if (fetched.peek()[turn.id]) return;
    const { [turn.id]: _, ...others } = failedTurns.peek();
    failedTurns.value = page.failed ? { ...others, [turn.id]: true } : others;
    const span = turn.range.end - turn.range.start;
    if (!page.entries.length && page.firstIndex === turn.range.start && span > 0) return;
    hold(turn.id, {
      entries: page.entries, items: shown(page.entries),
      hasEarlier: page.firstIndex > turn.range.start, firstIndex: page.firstIndex,
    });
  };

  /** The page before the one held, put in front of it. */
  const loadEarlierSteps = async (turn: ChatTurn) => {
    const have = fetched.peek()[turn.id];
    if (!turn.range || !have?.hasEarlier || earlierTurn.current === turn.id) return;
    earlierTurn.current = turn.id;
    const stamp = `${host}|${session}`;
    try {
      const page = await store.turnEntries(host, session, { start: turn.range.start, end: have.firstIndex });
      if (`${watchingSession.current}` !== stamp) return;
      const still = fetched.peek()[turn.id];
      if (!still) return;
      if (!page.entries.length) {
        // Nothing before what is held. A failed read starts where the turn does, and can be tried again.
        if (page.firstIndex >= still.firstIndex) hold(turn.id, { ...still, hasEarlier: false });
        return;
      }
      const seen = new Set(still.entries.map((entry) => entry.id));
      const entries = [...page.entries.filter((entry) => !seen.has(entry.id)), ...still.entries];
      hold(turn.id, {
        entries, items: shown(entries),
        hasEarlier: page.firstIndex > turn.range.start, firstIndex: page.firstIndex,
      });
    } finally {
      if (earlierTurn.current === turn.id) earlierTurn.current = null;
    }
  };

  // The same two for every turn, for as long as the chat is open, so a turn's props change only
  // when the turn does; each calls the latest of the functions above.
  const latest = useRef({ loadDetail, loadEarlierSteps });
  latest.current = { loadDetail, loadEarlierSteps };
  const turnActions = useMemo(() => ({
    loadDetail: (turn: ChatTurn) => latest.current.loadDetail(turn),
    loadEarlier: (turn: ChatTurn) => latest.current.loadEarlierSteps(turn),
  }), []);
  // The Prompts list's rows, while it is open, worked out again only when the chat changes,
  // not on every keystroke in its filter or every draw of the chat (#1850).
  const listing = listingPrompts.value && !!agent;
  const turnsNow = store.turns.value, entriesNow = store.entries.value, firstPrompt = store.firstPrompt.value ?? 0;
  const prompts = useMemo(() => listing ? sessionPrompts(turnsNow, entriesNow, live, firstPrompt) : [],
    [listing, turnsNow, entriesNow, live, firstPrompt]);

  return (
    <section class="chat" aria-label="Chat" ref={chatColumn}>
      {searchingFiles.value && agent && (
        <FileSearch place={nameOf(pathOf(agent.cwd))} search={findFiles} choose={openFound} close={() => (searchingFiles.value = false)} />
      )}
      {listingPrompts.value && agent && (
        <PromptList prompts={prompts}
          hasEarlier={store.firstTurn.value > 0 || store.hasMoreBefore.value}
          loadEarlier={store.hasMoreOfTheConversation ? () => store.loadEarlier() : undefined}
          close={() => (listingPrompts.value = false)}
          choose={(prompt) => {
            // To the prompt in the transcript, as Find goes to a match (#1532).
            focusedIndex.value = null;
            focusedEntry.value = prompt.id;
          }}
          branchFrom={agent.state !== "archived" && !down && store.has(host, Capability.chatBranch1) ? (prompt) => void branchFromPrompt(store, host, agent, prompt.id, prompt.text) : undefined}
          branchNeedsUpdate={agent.state !== "archived" && !store.has(host, Capability.chatBranch1)} />
      )}
      <header class="column-head">
        <BackToList />
        {agent && store.renaming.value?.id === agent.id && store.renaming.value.inChat
          ? <h1><RenameInput store={store} host={host} agent={agent} /></h1>
          : <h1>{agent?.title ?? "New session"}</h1>}
        <span class="actions">
          <button class="wide-only" onClick={() => replace({ ...r, files: !r.files })} aria-pressed={!!r.files}>Files</button>
          <SessionButtons store={store} host={host} agent={agent} disabled={down} />
          <SessionMenu store={store} host={host} agent={agent} disabled={down} inChat
            find={() => (finding.value = true)} findsOnHost={store.has(host, Capability.agentsFind1)} prompts={() => (listingPrompts.value = true)} openFile={() => (searchingFiles.value = true)}
            narrow={[
              { label: "Files", checked: !!r.files, run: () => replace({ ...r, files: !r.files }) },
            ]} />
        </span>
      </header>
      {hostDown && <OfflineStrip store={store} host={host} />}
      {!hostDown && <DiskStrip store={store} host={host} />}
      <FolderGoneNotice store={store} host={host} agent={agent} />
      <MissingFolderStrip store={store} host={host} agent={agent} />
      <AccountMoveStrip store={store} host={host} agent={agent} />
      <ContinueStrip store={store} host={host} agent={agent} disabled={down} />
      {/* What it keeps working towards (#2742), then what it said it would do, under what it
          waits on, as the Remote has them (#341). */}
      <GoalCard agent={agent} />
      <CurrentPlanStrip agent={agent} />
      {finding.value && agent && <FindBar store={store} host={host} agentID={agent.id} close={() => (finding.value = false)} />}
      <CallActionsContext.Provider value={callActions}>
      <ViewLayerContext.Provider value={viewHosting}>
      <div class="scroll transcript" ref={scroller} onScroll={onScroll} onWheel={onWheel}
        onTouchStart={onTouchStart} onTouchMove={onTouchMove}>
        <div class="view-layer" ref={(el) => { layer.element = el; }} />
        <ViewDiff layer={layer} openLink={(url) => { window.open(url, "_blank", "noopener,noreferrer"); }} />
        {failure && (
          // The history, or its earlier turns, did not load: said, with the way to ask again (#400).
          <p class="load-failure" role="status">
            <span>{failure.nothingLoaded ? "This chat's history did not load: " : "The earlier turns did not load: "}{failure.reason}</span>
            <button class="link" onClick={() => { void store.reloadTranscript(); }}>Try Again</button>
          </p>
        )}
        {store.hasMoreOfTheConversation && <p class="more" aria-label="Loading earlier"><span class="spinner" /></p>}
        {rows.map((turn, i) => (
          <TurnView key={turn.id} turn={turn} focusedRun={focusedRun.value}
            fetched={fetched.value[turn.id] && shownItems(fetched.value[turn.id]!.items)} fetchFailed={!!failedTurns.value[turn.id]} hasEarlier={fetched.value[turn.id]?.hasEarlier ?? false}
            auto={i >= rows.length - openTurnsHeld}
            isLive={i === rows.length - 1 && live} background={background}
            loadDetail={turnActions.loadDetail} loadEarlier={turnActions.loadEarlier} />
        ))}
        {agent && <Queued store={store} host={host} agent={agent} disabled={down} draftKey={`${host}|${session}`} />}
        {agent && <KeptBubbles store={store} kept={store.keptFor(host, agent.id)} />}
        {/* Live, at the foot: what the row says, until the prompt lands (ChatTranscript, #251). The one
            working mark on the page, never in a tool's or a thought's line (#2831). */}
        {agent && store.isComingBack(host, agent.id) ? <p class="working coming-back" aria-hidden="true">↻ {comingBackDescription}</p>
          : agent && (agent.state === "running" || agent.state === "starting") && (
          <p class="working" aria-hidden="true"><WorkingMark tool={runningTool(agent)} /></p>
        )}
        {/* What the foot says to a screen reader, as text, in one node that is always there: a
            live region reads a change to its text, not to an aria-label, nor a node just drawn (#2391). */}
        <p class="visually-hidden" role="status">{agent ? footStatusWords(agent, store.isComingBack(host, agent.id)) : ""}</p>
        {/* What it holds and waits for in line: what the agent is doing now, as the working line says (#2344). */}
        {agent && <LeaseLine store={store} host={host} agent={agent} />}
        {/* After all of it, where the reader is (#1995). */}
        {cards.length > 0 && (
          <div class="waiting" aria-label="Waiting for you">
            {cards.map((card) => <Fragment key={card.key}>{card.node}</Fragment>)}
          </div>
        )}
        {/* A wait on sessions or on a time, the same card in the same place (#2750): it was a strip
            under the chat's head with Carry on. */}
        {agent && openBlock(agent) && <BlockWaitCard store={store} host={host} agent={agent} disabled={down} />}
        {/* Under them, and not in "Waiting for you": the agent waits, not the person (#2084). Only
            while the wait is open: an ended one stays on the record until the agent goes on (#2749). */}
        {agent?.eventWait && agent.eventWait.ending === undefined && <WaitCard agent={agent} title={(id) => store.agent(host, id)?.title}
          disabled={down} stop={() => store.cancelWait(host, agent.id)} />}
        {agent && !store.isComingBack(host, agent.id) && agent.state !== "running" && agent.state !== "starting" && (
          <QuietLine since={lastEntryAt(store.entries.value, store.turns.value) ?? fromWireDate(agent.lastActivityAt)} />
        )}
      </div>
      {subagent.value && (
        <SubagentSteps store={store} item={agent?.background?.find((b) => b.id === subagent.value!.id) ?? subagent.value} close={() => (subagent.value = null)} />
      )}
      </ViewLayerContext.Provider>
      </CallActionsContext.Provider>
      {/* As JumpToEnd: one arrow to the end, shown whenever the reader is away from it (#1515). */}
      {away.value && (
        <button class="jump" onClick={toEnd} title="Go to the end" aria-label="Go to the end of the conversation">
          <span aria-hidden="true">↓</span>
        </button>
      )}
      <footer class="foot">
        <BackgroundRows store={store} host={host} agent={agent} disabled={down} steps={(item) => (subagent.value = item)} />
        <Prompt store={store} draftKey={`${host}|${session}`} placeholder={refusedHere ?? promptPlaceholder(agent)}
          disabled={(down && !keeps) || !agent || refusedHere !== null}
          stop={agent && hasTurnInFlight(agent) ? () => void store.perform(host, agent.id, "agents/stop") : undefined}
          acting={agent && store.onItsWay.value[agent.id]}
          queues={willQueue(agent)} suggestion={agent?.suggestedPrompts?.[0]}
          banner={agent && <CostLimitBanner agent={agent} costs={store.costs.value[host]}
            goOn={() => void store.letAgentGoOn(host, agent)} />}
          recipient={store.recipient(host)}
          capabilities={agent ? store.account(host, agent.runtimeID)?.promptCapabilities : undefined}
          sent={agent ? sentPrompts(store.turns.value, store.entries.value) : []}
          send={(text, attachments) => {
            // Sending is asking for the end, as the window's prompt does (#378).
            toEnd();
            return store.prompt(host, session, text, attachments);
          }}
          onTyping={() => store.prewarm(host, session, "typing")}
          commands={agent?.availableCommands}
          findFiles={agent ? findFiles : undefined}
          where={agent && (
            <>
              <Place store={store} host={host} agent={agent} />
              {r.folder && <Labels store={store} host={host} agent={agent} folder={r.folder} disabled={down} />}
            </>
          )}
          runtime={agent && <RuntimeLabel store={store} host={host} agent={agent} />}>
          {agent && (
          <PromptMenus options={drawable(agent.advertisedOptions, [])} disabled={down} runtime={runtimeNameOn(store, host, agent.runtimeID)}
              runtimeID={agent.runtimeID}
              clientPermission={{
                own: agent.clientPermission,
                settings: store.clientPermissions.value[store.macHostID.value]?.[agent.runtimeID as Exclude<keyof ClientPermissionSettings, "setBy">] ?? "default",
                set: (mode) => void store.setAgentClientPermission(host, agent.id, mode),
              }}
              levels={{
                runtimeName: runtimeNameOn(store, host, agent.runtimeID),
                chosen: (field) => agent.levels?.[field],
                cell: (field, level) => cellOf(store.autoMappings.value[store.macHostID.value], agent.runtimeID, field, level),
                choose: (field, level) => void store.setLevels(host, agent.id, field, level),
              }}
              value={(o) => store.pendingOptions.value[agent.id]?.[o.id] ?? agent.startOptions.values[o.id] ?? o.currentValue}
              onChange={(o, v) => void store.setOption(host, agent.id, o.id, v)}
              trailing={<ContextMeter agent={agent} costs={store.costs.value[host]} />}
              besideMode={<SandboxCapsule runtimeID={agent.runtimeID} override={agent.sandboxOverride}
                runtimeDefault={store.sandboxDefaults.value[host]?.[agent.runtimeID] ?? "runtime"}
                mode={typeof agent.startOptions.values.mode === "string" ? agent.startOptions.values.mode : undefined} disabled={down}
                setBy={store.sandboxSetBy.value[host]}
                onChange={(choice) => void store.setAgentSandbox(host, agent.id, choice)} />} />
          )}
        </Prompt>
      </footer>
    </section>
  );
}

/**
 * Where it works (PromptBar's placeTitle): its worktree, else the folder's branch. Said,
 * not offered: moving a session to another worktree is the window's.
 */
function Place({ store, host, agent }: { store: Store; host: string; agent: Agent }) {
  const branch = useSignal<string | undefined>(undefined);
  const folder = folderPath(agent);
  useEffect(() => {
    branch.value = undefined;
    if (agent.worktree) return;
    void store.worktrees(host, folder).then((list) => {
      branch.value = list?.worktrees.find((w) => w.isFolder)?.branch;
    });
  }, [host, folder, agent.worktree?.root]);
  const title = agent.worktree?.name ?? branch.value ?? "Folder";
  const help = agent.worktree ? `Worktree ${agent.worktree.name}${agent.worktree.branch ? ` on ${agent.worktree.branch}` : ""}` : "The folder";
  return <span class="pill place" title={help} aria-label={`Works in: ${title}`}>{title}</span>;
}

/** The runtime the conversation is on (PromptBar's runtimeLabel): said, not offered. */
function runtimeNameOn(store: Store, host: string, runtimeID: string): string {
  return (store.runtimes.value[host] ?? []).find((r) => r.runtime.id === runtimeID)?.runtime.name ?? runtimeID;
}

/** With the account it runs on, when that is not the runtime's own sign-in: "Claude · Work" (#2259). */
function RuntimeLabel({ store, host, agent }: { store: Store; host: string; agent: Agent }) {
  const named = sessionRuntimeName(runtimeNameOn(store, host, agent.runtimeID), agent.runtimeID, agent.accountID,
    store.accountProfiles.value[host] ?? []);
  // An Auto agent says so, with the runtime it picked (#2658, FR-009).
  const name = agent.auto ? autoHeader(named) : named;
  const title = agent.accountID === undefined ? "Runtime" : "Runtime and account";
  return <span class="pill" title={title} aria-label={`Runtime: ${name}`}>{name}</span>;
}

/**
 * Something typed while the agent worked, where it will appear (QueuedPromptRow), removable, and
 * with Send now while a turn runs on a runtime that takes words mid-turn.
 */
function Queued({ store, host, agent, disabled, draftKey }: { store: Store; host: string; agent: Agent; disabled: boolean; draftKey: string }) {
  const canSendNow = (agent.state === "running" || agent.state === "waitingOnUser")
    && store.account(host, agent.runtimeID)?.canSteer === true;
  /** The prompt being changed and its words, while Edit is open (#1552). */
  const editing = useSignal<{ id: string; text: string } | null>(null);
  // Focused once, when Edit opens it (#1678): a ref that focuses on every render took the caret
  // back from the prompt bar each time a streamed entry drew the chat again.
  const editor = useRef<HTMLTextAreaElement>(null);
  const editingID = editing.value?.id;
  useEffect(() => { if (editingID) editor.current?.focus(); }, [editingID]);
  const save = (id: string, before: string) => {
    const words = editing.value?.text ?? before;
    editing.value = null;
    if (words !== before && words.trim()) void store.editQueued(host, agent.id, id, words, draftKey);
  };
  // Sent while it was being changed: the change is asked for anyway, and comes back as words in the prompt bar.
  const open = editing.value;
  const stillQueued = !open || (agent.queuedPrompts ?? []).some((q) => q.id === open.id);
  useEffect(() => {
    if (!stillQueued && open) {
      editing.value = null;
      void store.editQueued(host, agent.id, open.id, open.text, draftKey);
    }
  }, [stillQueued]);
  // Held while anything is on its way to this agent; the one going, said (#87).
  const acting = store.onItsWay.value[agent.id];
  return (
    <>
      {(agent.queuedPrompts ?? []).map((queued) => {
        const going = typeof acting === "object" && acting.sendNow === queued.id;
        if (editing.value?.id === queued.id) {
          // Edit open (#1552): the words in the bubble's place, Cancel and Save under them; Save keeps its place.
          return (
            <div key={queued.id} class="queued editing">
              <textarea class="queued-editor" aria-label="Queued prompt" rows={Math.min(12, Math.max(2, editing.value.text.split("\n").length))}
                value={editing.value.text} ref={editor}
                onInput={(e) => (editing.value = { id: queued.id, text: (e.currentTarget as HTMLTextAreaElement).value })}
                onKeyDown={(e) => {
                  if (e.key === "Escape") { e.preventDefault(); editing.value = null; }
                  if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); save(queued.id, queued.text); }
                }} />
              <div class="queued-actions">
                <button class="link" onClick={() => (editing.value = null)}>Cancel</button>
                <button class="link" disabled={!editing.value.text.trim()} onClick={() => save(queued.id, queued.text)}>Save</button>
              </div>
            </div>
          );
        }
        // The person's bubble, dashed and dimmed, with what can be done to it underneath (#95).
        return (
        <div key={queued.id} class="queued">
          {queued.from === "agent" && <p class="faint">{fromLine(queued.sender?.title)}</p>}
          <div class="queued-bubble" role="group"
            aria-label={queued.from === "agent" ? `Queued, ${fromLine(queued.sender?.title)}: ${queued.text}` : `Queued: ${queued.text}`}>
            <p>{queued.text}</p>
            {queued.attachments.length > 0 && <p class="small">📎 {queued.attachments.map((a) => a.displayName).join(", ")}</p>}
          </div>
          <div class="queued-actions">
            {canSendNow && (going ? <Telling recipient={store.recipient(host)} doing="Sending" /> : (
              <button class="link" disabled={disabled || !!acting} title="Send this into the turn that is running, without waiting for it to end"
                onClick={() => void store.sendNow(host, agent.id, queued.id)}>↑ Send now</button>
            ))}
            {/* The person's own words only: another agent's are theirs (#560). On a host too old to change them (#1748), greyed and saying why (#1866). */}
            {(queued.from ?? "person") === "person" && (
              <button class="link" aria-label="Edit queued prompt"
                title={store.has(host, Capability.agentsEditQueued1) ? "Change the words. It keeps its place in the queue." : hostNeedsUpdate}
                disabled={disabled || going || !store.has(host, Capability.agentsEditQueued1)}
                onClick={() => (editing.value = { id: queued.id, text: queued.text })}>Edit</button>
            )}
            <button class="remove" aria-label="Remove queued prompt" title="Do not send this" disabled={disabled || going}
              onClick={() => void store.unqueue(host, agent.id, queued.id)}>×</button>
          </div>
        </div>
        );
      })}
    </>
  );
}

/**
 * What the open agent holds and waits for in line, with the working line (036; LeaseLine.swift,
 * #2344): one line each, a way to the Resources page, with a chevron and a row's hit area (#2448). What it waits for on events is a card (#1995).
 */
function LeaseLine({ store, host, agent }: { store: Store; host: string; agent: Agent }) {
  // A place in line that the wait card says is left to the card (#2361).
  const leases = leaseMark(agent.id, store.leases.value[host], (id) => store.agent(host, id)?.title, lineResource(agent));
  if (!leases) return null;
  return (
    <div class="lease-line" role="status" aria-label={leases.full}>
      {leases.lines.map((text) => (
        <button key={text} class="link" title={leases.full}
          onClick={() => { location.hash = routeHash({ nav: "machines", section: "resources" }); }}>
          <span class="words">{text}</span><span class="chevron" aria-hidden="true">›</span>
        </button>
      ))}
    </div>
  );
}

/**
 * The agent's wait on events, as a card under the questions (WaitCard.swift, #1995): what, since
 * when, until when, a way to it on the Events page, and Stop Waiting. Not tinted.
 */
function WaitCard({ agent, title, disabled, stop }: { agent: Agent; title: (id: string) => string | undefined;
  disabled: boolean; stop: () => Promise<void> }) {
  const busy = useSignal(false);
  const now = useSignal(Date.now());
  useEffect(() => {
    const timer = window.setInterval(() => { now.value = Date.now(); }, 20_000);
    return () => window.clearInterval(timer);
  }, []);
  const wait = agent.eventWait;
  const line = eventWaitLine(agent, title);
  if (!wait || wait.ending !== undefined || (!line && wait.patterns.length === 0)) return null;
  const { elapsed, total, percent } = eventWaitMinutes(wait, new Date(now.value));
  return (
    <div class="cards">
      <div class="card wait-card">
        {lineResource(agent) !== undefined ? <p class="strong">{line}</p> : <>
          <div class="wait-card-heading">
            <span class="wait-card-title"><span class="wait-card-broadcast" aria-hidden="true"><Beacon /></span>Waiting for event</span>
            <span class="wait-card-time">{total === undefined ? `${elapsed} min` : `${elapsed} / ${total} min`}</span>
          </div>
          <div class="wait-card-events">
            {eventWaitSummaryLines(wait, title).map((line) => <p class="wait-card-event" key={line.id} title={line.events.join(", ")}>
              <span class="wait-card-source">{line.source}</span><span class="wait-card-separator">·</span>
              <span class="wait-card-kind">{line.words}</span>
              {line.arguments.length > 0 && <span class="wait-card-filters">({line.arguments.join(", ")})</span>}
            </p>)}
          </div>
          {percent !== undefined && <div class="wait-card-progress" role="progressbar" aria-label="Event wait time"
            aria-valuemin={0} aria-valuemax={100} aria-valuenow={percent}>
            <span style={{ width: `${percent}%` }} />
          </div>}
        </>}
        <p class="wait-answers">
          <button onClick={() => { location.hash = routeHash({ nav: "reports", section: "events" }); }}>Show in Events</button>
          <button disabled={disabled || busy.value} title="Stop waiting. Nothing will start it again for this wait."
            onClick={() => { busy.value = true; void stop().finally(() => (busy.value = false)); }}>Stop Waiting</button>
        </p>
      </div>
    </div>
  );
}

/**
 * A wait on sessions or on a time (BlockWaitCard in WaitCard.swift, #2750), drawn as WaitCard is:
 * what it waits on, since when, when it checks again, and Stop Waiting, which carries it on now.
 */
function BlockWaitCard({ store, host, agent, disabled }: { store: Store; host: string; agent: Agent; disabled: boolean }) {
  const busy = useSignal(false);
  const now = useSignal(Date.now());
  useEffect(() => {
    const timer = window.setInterval(() => { now.value = Date.now(); }, 20_000);
    return () => window.clearInterval(timer);
  }, []);
  const block = openBlock(agent);
  if (!block || !agent.report) return null;
  const since = fromWireDate(agent.report.at).getTime();
  const deadline = block.checkAgainAt === undefined ? undefined : fromWireDate(block.checkAgainAt).getTime();
  const total = deadline === undefined ? undefined : Math.max(1, Math.ceil((deadline - since) / 60_000));
  const elapsed = Math.max(0, Math.floor((now.value - since) / 60_000));
  const share = deadline === undefined || deadline <= since ? undefined : Math.min(100, Math.max(0, (now.value - since) / (deadline - since) * 100));
  return (
    <div class="cards">
      <div class="card wait-card block-wait-card">
        <div class="wait-card-heading">
          <span class="wait-card-title"><span class="wait-card-broadcast" aria-hidden="true"><Beacon /></span>{cardTitle(block)}</span>
          <span class="wait-card-time">{total === undefined ? `${elapsed} min` : `${elapsed} / ${total} min`}</span>
        </div>
        <div class="wait-card-events">
          {store.waitsOf(host, agent).map((line) => <p class="wait-card-event" key={line}>{line}</p>)}
        </div>
        {share !== undefined && <div class="wait-card-progress" role="progressbar" aria-label="Wait time"
          aria-valuemin={0} aria-valuemax={100} aria-valuenow={share}><span style={{ width: `${share}%` }} /></div>}
        <p class="wait-answers">
          <button disabled={disabled || busy.value} title={carryOnHelp(agent)}
            onClick={() => { busy.value = true; void store.prompt(host, agent.id, carryOnPrompt, []).finally(() => (busy.value = false)); }}>Stop Waiting</button>
        </p>
      </div>
    </div>
  );
}

/**
 * One subagent: who it is, what it was asked, and what it did (SubagentStepsView, #544), in a
 * sheet over the chat as the phone has it. Its steps are those among the chat's loaded entries.
 */
function SubagentSteps({ store, item, close }: {
  store: Store; item: BackgroundItem; close: () => void;
}) {
  const now = useSignal(toWireDate(new Date()));
  useEffect(() => {
    const timer = setInterval(() => (now.value = toWireDate(new Date())), 1_000);
    return () => clearInterval(timer);
  }, []);
  const shows = showsThoughts.value;
  const steps = useMemo(() => shownItems(display(store.entries.value, item.id), shows), [store.entries.value, item.id, shows]);
  return (
    <Modal label={`Subagent ${item.name}`} close={close}>
      <div class="sheet-body subagent-steps">
        <h2>{item.name}</h2>
        <p class="quiet small">{subagentStatus(item, now.value)}</p>
        {item.detail && (
          <div class="asked">
            <p class="faint small">Asked to</p>
            <p>{item.detail}</p>
          </div>
        )}
        {!steps.length && <p class="faint small">{subagentNoSteps(item)}</p>}
        {/* Thinking too when Show thoughts is on, each a folded line (#1315, #1725). */}
        <div class="steps">{steps.map((step) => <ItemRow key={step.id} item={step} background={[]} />)}</div>
        <div class="sheet-actions"><button onClick={close}>Done</button></div>
      </div>
    </Modal>
  );
}

/**
 * What the agent left running, over the prompt (057): Stop on what the runtime can stop, and a
 * subagent says it stops with the agent and opens its Steps, as BackgroundItemRow (#253, #544).
 */
function BackgroundRows({ store, host, agent, disabled, steps }: {
  store: Store; host: string; agent: Agent | undefined; disabled: boolean; steps: (item: BackgroundItem) => void;
}) {
  const now = useSignal(toWireDate(new Date()));
  const items = (agent?.background ?? []).filter(isRunning);
  useEffect(() => {
    if (!items.length) return;
    const timer = setInterval(() => (now.value = toWireDate(new Date())), 1_000);
    return () => clearInterval(timer);
  }, [items.length]);
  if (!items.length) return null;
  return (
    <ul class="background" aria-label="In the background">
      {items.map((item) => (
        <li key={item.id} title={item.command ?? item.detail ?? item.name} class={item.isStopping ? "stopping" : undefined}>
          <span class="noun">{backgroundNoun(item)}</span> {item.name}
          <span class="age">{item.isStopping ? "Stopping…" : backgroundEnded(item) ?? backgroundAge(item, now.value)}</span>
          {item.kind === "subagent" && (
            <button class="stop" title="See what this subagent is doing" onClick={() => steps(item)}>Steps</button>
          )}
          {item.canStop ? (
            <button class="stop" disabled={disabled || item.isStopping} aria-label={`Stop ${item.name}`}
              title={`Stop ${item.name}, and nothing else the agent is doing`}
              onClick={() => agent && void store.stopBackground(host, agent.id, item.id)}>Stop</button>
          ) : item.kind === "subagent" && (
            <span class="faint" title="Neither Claude nor Codex can stop one subagent alone. Stop the agent to stop it.">stops with the agent</span>
          )}
        </li>
      ))}
    </ul>
  );
}

/** When the conversation last did anything: its last entry, or the last stored turn's (AgentsModel.lastEntryAt). */
function lastEntryAt(entries: readonly TranscriptEntry[], turns: readonly TurnSummary[]): Date | null {
  const turn = turns[turns.length - 1];
  const at = entries[entries.length - 1]?.at ?? turn?.outcome?.[turn.outcome.length - 1]?.at ?? turn?.last?.at ?? turn?.ask?.at;
  return at === undefined ? null : fromWireDate(at);
}

/** How long the chat has been quiet, at its foot (QuietLine, #1564). Nothing under five minutes; read again on the minute. */
function QuietLine({ since }: { since: Date }) {
  const now = useSignal(new Date());
  useEffect(() => {
    const timer = setInterval(() => (now.value = new Date()), 60_000);
    return () => clearInterval(timer);
  }, []);
  const line = quietLine(since, now.value);
  return line ? <p class="quiet-line" title={since.toLocaleString()}>{line}</p> : null;
}

/**
 * Find in Chat (ChatFindBar, #1532): what was said in the open chat, found by its host, newest match
 * first. Enter and ↑ go back through the chat, Shift-Enter and ↓ come forward, Escape closes it.
 */
/** Said in the count's place when the host could not search (#1680), as ChatFindBar.failed says it. */
const findFailed = "Couldn't search this chat";

function FindBar({ store, host, agentID, close }: { store: Store; host: string; agentID: string; close: () => void }) {
  const text = useSignal("");
  // Focused once, when the bar opens (#1678), not on every render of the chat under it.
  const field = useRef<HTMLInputElement>(null);
  useEffect(() => { field.current?.focus(); }, []);
  const result = useSignal<FindResult | null>(null);
  const at = useSignal<number | null>(null);
  /** The last search did not reach the host, or the host could not do it (#1680). */
  const failed = useSignal(false);
  const go = async (match: FindMatch) => {
    await store.loadUntil(match.index);
    focusedIndex.value = match.index;
    focusedEntry.value = match.entryID;
  };
  // A pause in the typing, then the host is asked; a newer word drops the older answer.
  useEffect(() => {
    const words = text.value.trim();
    if (!words) {
      result.value = null;
      at.value = null;
      failed.value = false;
      return;
    }
    let gone = false;
    const timer = setTimeout(() => {
      void store.find(host, agentID, words).then((found) => {
        if (gone) return;
        // Not the last search's count: that would be read as this one's (#1680).
        failed.value = !found;
        if (!found) {
          result.value = null;
          at.value = null;
          return;
        }
        result.value = found;
        at.value = found.matches.length ? found.matches.length - 1 : null;
        if (at.value !== null) void go(found.matches[at.value]!);
      });
    }, 250);
    return () => { gone = true; clearTimeout(timer); };
  }, [text.value, agentID]);
  const matches = result.value?.matches ?? [];
  const step = (back: boolean) => {
    if (at.value === null) return;
    const next = at.value + (back ? -1 : 1);
    if (next < 0 || next >= matches.length) return;
    at.value = next;
    void go(matches[next]!);
  };
  const count = failed.value ? findFailed : !result.value ? null : at.value === null ? "No matches"
    : `${at.value + 1} of ${matches.length}${result.value.more ? "+" : ""}`;
  return (
    <div class="find-bar" role="search">
      <input type="search" aria-label="Find in Chat" placeholder="Find in Chat" value={text.value} ref={field}
        onInput={(e) => (text.value = (e.currentTarget as HTMLInputElement).value)}
        onKeyDown={(e) => {
          if (e.key === "Escape") { e.preventDefault(); close(); }
          else if (e.key === "Enter" || e.key === "ArrowUp" || e.key === "ArrowDown") {
            e.preventDefault();
            step(e.key === "ArrowUp" || (e.key === "Enter" && !e.shiftKey));
          }
        }} />
      {count && <span class="faint small" aria-live="polite">{count}</span>}
      <button class="link" aria-label="Earlier match" title="Earlier match" disabled={!at.value} onClick={() => step(true)}>↑</button>
      <button class="link" aria-label="Later match" title="Later match" disabled={at.value === null || at.value >= matches.length - 1} onClick={() => step(false)}>↓</button>
      <button class="link" onClick={close}>Done</button>
    </div>
  );
}

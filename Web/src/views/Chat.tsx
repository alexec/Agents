// The chosen session's chat (071 US2, FR-023): concise turns at the chosen level (069), tool
// calls, plans and background tasks (057), live from agent/entry and agent/changed; the cards
// where each was asked (#973); the prompt pinned to the foot at every width (US6 scenario 4), with where
// the session works, its labels and its runtime over it, as in the window (#108). Long
// conversations come a page at a time as the top is reached, and the pane follows the end
// unless the person has scrolled up.
import { Fragment } from "preact";
import { useSignal } from "@preact/signals";
import { useEffect, useLayoutEffect, useMemo, useRef } from "preact/hooks";
import { openTurnsHeld, rememberOpen, type Store } from "../model/store";
import { backgroundAge, backgroundEnded, backgroundNoun, isRunning, subagentNoSteps, subagentStatus } from "../model/background";
import { display, isPersonsAsk, isWorking, placing, type ChatTurn, type Item } from "../model/turns";
import { toWireDate } from "../protocol/dates";
import type { Agent, AppViewCall, BackgroundItem, FileMentionDTO, TranscriptEntry } from "../protocol/generated";
import { replace, route } from "../route";
import { useWaitingCards, type WaitingCard } from "./Cards";
import { OfflineStrip } from "./OfflineStrip";
import { DiskStrip } from "./DiskStrip";
import { KeptBubbles } from "./Kept";
import { FolderGoneNotice, MissingFolderStrip } from "./MissingFolder";
import { BlockStrip } from "./BlockStrip";
import { CurrentPlanStrip } from "./PlanStrip";
import { Telling } from "./Telling";
import { Labels } from "./Labels";
import { Prompt } from "./Prompt";
import { PromptMenus } from "./PromptMenus";
import { ContextMeter, CostLimitBanner, SandboxCapsule } from "./PromptStatus";
import { RenameInput, SessionButtons, SessionMenu } from "./SessionMenu";
import { drawable } from "../model/options";
import { asksToArchive, projectFolder } from "../model/groups";
import { initialDetail, toggled } from "../model/turnDetail";
import { CallActionsContext, fromLine, ItemRow, TurnView, type CallActions, type TurnDetail } from "./chat/Rows";
import { Modal } from "./Modal";
import { nameOf, pathOf, setPane } from "./files/paneState";
import { FileSearch, isOpenFileKey } from "./files/FileSearch";
import { focusedEntry } from "../model/focus";
import { ViewLayerContext } from "./chat/AppView";
import { recipient, type Start, viewPin } from "./chat/appViewBridge";
import { ViewLayer, type ViewActions } from "./chat/viewLayer";
import { offerStart } from "./NewAgent";
import { BackToList } from "./BackToList";
import { comingBackDescription } from "../model/status";
import { ArchiveCard } from "./ArchiveCard";
import { hasTurnInFlight, promptPlaceholder, willQueue } from "../model/promptWords";
import { eventWaitCapsule, leaseMark } from "../model/rowLines";
import { GuardedChangeCard } from "./GuardedChange";

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
  /** Turns opened or closed by hand, kept until the chat is left. */
  const chosen = useSignal<Record<string, TurnDetail>>({});
  /** The run of calls gone to from elsewhere: opened, with its first call (#1315). */
  const focusedRun = useSignal<string | null>(null);
  /** The few opened turns whose entries are held, newest last (#291). */
  const fetched = useSignal<Record<string, HeldTurn>>({});
  /** Turns whose steps were asked for and did not come, until asked again (#544). */
  const failedTurns = useSignal<Record<string, true>>({});
  /** The subagent whose steps are open over the chat, as the phone's sheet (#544). */
  const subagent = useSignal<BackgroundItem | null>(null);
  const openedTurns = useRef<string[]>([]);
  const earlierTurn = useRef<string | null>(null);
  /** Which chat a turn's page was asked for, so a reply for one left behind is dropped. */
  const watchingSession = useRef(`${host}|${session}`);
  watchingSession.current = `${host}|${session}`;
  const newBelow = useSignal(false);

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
      // Answered only while the agent waits on it, and while its host answers (#253).
      waitingSandbox: agent?.pendingSandboxFailure,
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
  }, [host, session, agent?.pendingSandboxFailure, down]);

  const scroller = useRef<HTMLDivElement>(null);
  const chatColumn = useRef<HTMLElement>(null);
  // The chat's views (#187): one layer while the chat is open, its views told and taken down
  // when another chat opens, and when the page leaves the chat.
  const layer = useMemo(() => new ViewLayer(), []);
  const pinFolder = agent ? projectFolder(agent) : undefined;
  const viewHosting = useMemo(() => {
    const actions: ViewActions = {
      agentID: session,
      call: (method, params) => store.link.call(method, params as never, host) as Promise<unknown>,
      send: (text) => store.prompt(host, session, text, []),
      // Pin (#189): under the project the chat works in.
      ...(pinFolder ? { pin: (call: AppViewCall) => store.pinView(host, pinFolder, viewPin(call)) } : {}),
      // A new agent, filled in by the view (#834): the form in the chat's project.
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
    chosen.value = {};
    focusedRun.value = null;
    fetched.value = {};
    failedTurns.value = {};
    subagent.value = null;
    openedTurns.current = [];
    following.current = true;
    away.value = false;
    store.setFollowingEnd(true);
    newBelow.value = false;
    settled.current = false;
    const timer = setTimeout(() => (settled.current = true), 400);
    return () => clearTimeout(timer);
  }, [session]);

  // Following the end: every kind of growth, a new line or a longer one, keeps the foot in view.
  const entryCount = store.entries.value.length;
  useLayoutEffect(() => {
    const el = scroller.current;
    if (!el || loadingEarlier.current) return;
    if (following.current) el.scrollTop = el.scrollHeight;
    else if (settled.current) newBelow.value = true;
  }, [entryCount, store.turns.value.length, session]);
  // Every row is watched, those drawn since too: a queued bubble or a card that grows without an
  // entry arriving used to leave the foot a frame or more behind (#378).
  const sizes = useRef<ResizeObserver | null>(null);
  useLayoutEffect(() => {
    const el = scroller.current;
    if (!el) return;
    const watcher = new ResizeObserver(() => {
      if (following.current && !loadingEarlier.current) el.scrollTop = el.scrollHeight;
    });
    sizes.current = watcher;
    watcher.observe(el);
    return () => { watcher.disconnect(); sizes.current = null; };
  }, []);
  useLayoutEffect(() => {
    const el = scroller.current;
    if (el && sizes.current) for (const child of Array.from(el.children)) sizes.current.observe(child);
  });

  const earlier = async () => {
    const el = scroller.current;
    if (!el || loadingEarlier.current || !settled.current || !store.hasMoreOfTheConversation) return;
    loadingEarlier.current = true;
    // Hold the line being read: what arrives goes above it.
    const fromBottom = el.scrollHeight - el.scrollTop;
    await store.loadEarlier();
    requestAnimationFrame(() => {
      el.scrollTop = el.scrollHeight - fromBottom;
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
      else if (fromBottom < 1 || (fromBottom < atTheEnd && el.scrollTop > was.top)) {
        follow(true);
        newBelow.value = false;
      }
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
      focusedEntry.value = null;
      return;
    }
    if (turn && (chosen.value[turn.id] ?? initialDetail) === "collapsed") {
      follow(false);
      chosen.value = { ...chosen.value, [turn.id]: "open" };
    }
  }, [focus, rows, chosen.value]);

  // What waits on the person is in the conversation, not over it (#723), each where it was asked:
  // what came after it is below it (#973). Scrolled out of sight, the way back says a question is
  // waiting, and which way.
  const asked = useWaitingCards({ store, host, session, down });
  const cards: WaitingCard[] = [
    // A change its agent made to the project's own files, asked here (#531).
    ...store.guardedChanges(host, { session }).map(({ folder, change }) => ({
      key: `guarded:${folder}|${change.path}`, at: change.since,
      node: <div class="cards"><GuardedChangeCard store={store} host={host} folder={folder} change={change} down={down} /></div>,
    })),
    ...asked,
    // An ask to be archived waits the same way, last when asked at once (#827).
    ...(agent && asksToArchive(agent) ? [{
      key: `archive:${agent.id}`,
      at: agent.archiveRequest && "requested" in agent.archiveRequest ? agent.archiveRequest.requested.at : Infinity,
      node: <ArchiveCard store={store} host={host} agent={agent} disabled={down} />,
    }] : []),
  ];
  const stretches = placing(rows, cards, (card) => card.at);
  const firstCard = stretches.findIndex((stretch) => stretch.cards.length > 0);
  const firstCardKey = firstCard < 0 ? null : stretches[firstCard]!.cards[0]!.key;
  const cardsAtTheEnd = firstCard >= 0 && firstCard === stretches.length - 1;
  const waiting = useRef<HTMLDivElement>(null);
  const waitingPlace = useSignal<"shown" | "above" | "below">("shown");
  useEffect(() => {
    const el = waiting.current;
    const root = scroller.current;
    if (!el || !root) return;
    const watcher = new IntersectionObserver(([seen]) => {
      if (!seen) return;
      waitingPlace.value = seen.isIntersecting ? "shown"
        : seen.boundingClientRect.bottom <= (seen.rootBounds?.top ?? 0) ? "above" : "below";
    }, { root, threshold: 0.2 });
    watcher.observe(el);
    return () => watcher.disconnect();
  }, [host, session, firstCardKey]);
  const questionWaiting = cards.length > 0 && waitingPlace.value !== "shown";
  const questionAbove = questionWaiting && waitingPlace.value === "above";

  const toEnd = () => {
    const el = scroller.current;
    follow(true);
    newBelow.value = false;
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

  // To the first waiting card (#973). At the end it is the end, and following goes on; anywhere
  // else it is a place in the middle, as a line the reader is sent to is, and following stops.
  const toQuestion = () => {
    if (cardsAtTheEnd && !questionAbove) return toEnd();
    follow(false);
    waiting.current?.scrollIntoView({ block: "start", behavior: "smooth" });
  };

  const toggle = (turn: ChatTurn) => {
    chosen.value = { ...chosen.value, [turn.id]: toggled(chosen.value[turn.id] ?? initialDetail) };
  };

  // A turn closed lets its entries go (#291).
  useEffect(() => {
    const openNow = new Set<string>();
    for (const turn of rows) if ((chosen.value[turn.id] ?? initialDetail) !== "collapsed") openNow.add(turn.id);
    const drop = openedTurns.current.filter((id) => !openNow.has(id));
    if (!drop.length) return;
    const next = { ...fetched.peek() };
    let changed = false;
    for (const id of drop) if (id in next) { delete next[id]; changed = true; }
    openedTurns.current = openedTurns.current.filter((id) => openNow.has(id));
    if (changed) fetched.value = next;
  }, [rows, chosen.value]);

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

  // The same three for every turn, for as long as the chat is open, so a turn's props change only
  // when the turn does; each calls the latest of the functions above.
  const latest = useRef({ toggle, loadDetail, loadEarlierSteps });
  latest.current = { toggle, loadDetail, loadEarlierSteps };
  const turnActions = useMemo(() => ({
    toggle: (turn: ChatTurn) => latest.current.toggle(turn),
    loadDetail: (turn: ChatTurn) => latest.current.loadDetail(turn),
    loadEarlier: (turn: ChatTurn) => latest.current.loadEarlierSteps(turn),
  }), []);

  return (
    <section class="chat" aria-label="Chat" ref={chatColumn}>
      {searchingFiles.value && agent && (
        <FileSearch place={nameOf(pathOf(agent.cwd))} search={findFiles} choose={openFound} close={() => (searchingFiles.value = false)} />
      )}
      <header class="column-head">
        <BackToList />
        {agent && store.renaming.value?.id === agent.id && store.renaming.value.inChat
          ? <h1><RenameInput store={store} host={host} agent={agent} /></h1>
          : <h1>{agent?.title ?? "New session"}</h1>}
        <span class="actions">
          <button class="wide-only" onClick={() => replace({ ...r, files: !r.files })} aria-pressed={!!r.files}>Files</button>
          <SessionButtons store={store} host={host} agent={agent} disabled={down} />
          <SessionMenu store={store} host={host} agent={agent} disabled={down} inChat openFile={() => (searchingFiles.value = true)}
            narrow={[
              { label: "Files", checked: !!r.files, run: () => replace({ ...r, files: !r.files }) },
            ]} />
        </span>
      </header>
      {hostDown && <OfflineStrip store={store} host={host} />}
      {!hostDown && <DiskStrip store={store} host={host} />}
      <FolderGoneNotice store={store} host={host} agent={agent} />
      <MissingFolderStrip store={store} host={host} agent={agent} />
      <BlockStrip store={store} host={host} agent={agent} disabled={down} />
      {/* What it said it would do, under what it waits on, as the Remote has it (#341). */}
      <CurrentPlanStrip agent={agent} />
      <CallActionsContext.Provider value={callActions}>
      <ViewLayerContext.Provider value={viewHosting}>
      <div class="scroll transcript" ref={scroller} onScroll={onScroll}>
        <div class="view-layer" ref={(el) => { layer.element = el; }} />
        {failure && (
          // The history, or its earlier turns, did not load: said, with the way to ask again (#400).
          <p class="load-failure" role="status">
            <span>{failure.nothingLoaded ? "This chat's history did not load: " : "The earlier turns did not load: "}{failure.reason}</span>
            <button class="link" onClick={() => { void store.reloadTranscript(); }}>Try Again</button>
          </p>
        )}
        {store.hasMoreOfTheConversation && <p class="more" aria-label="Loading earlier"><span class="spinner" /></p>}
        {(() => {
          // Each stretch's turns, then the cards asked after them, in one keyed list: a card answered
          // lets the turns around it join up without drawing them again (#973).
          const drawn = stretches.reduce((n, stretch) => n + stretch.turns.length, 0);
          let index = 0;
          return stretches.flatMap((stretch, at) => [
            ...stretch.turns.map((turn) => {
              const i = index++;
              return (
                <TurnView key={turn.id} turn={turn} detail={chosen.value[turn.id] ?? initialDetail} focusedRun={focusedRun.value}
                  fetched={fetched.value[turn.id]?.items} fetchFailed={!!failedTurns.value[turn.id]} hasEarlier={fetched.value[turn.id]?.hasEarlier ?? false}
                  auto={i >= drawn - openTurnsHeld}
                  isLive={i === drawn - 1 && live} background={background}
                  toggle={turnActions.toggle} loadDetail={turnActions.loadDetail} loadEarlier={turnActions.loadEarlier} />
              );
            }),
            ...(stretch.cards.length ? [
              <div key={`waiting:${stretch.cards[0]!.key}`} class="waiting" aria-label="Waiting for you"
                {...(at === firstCard ? { ref: waiting } : {})}>
                {stretch.cards.map((card) => <Fragment key={card.key}>{card.node}</Fragment>)}
              </div>,
            ] : []),
          ]);
        })()}
        {agent && <Queued store={store} host={host} agent={agent} disabled={down} />}
        {agent && <KeptBubbles store={store} kept={store.keptFor(host, agent.id)} />}
        {/* Live, at the foot: what the row says, until the prompt lands (ChatTranscript, #251). */}
        {agent && store.isComingBack(host, agent.id) ? <p class="working coming-back" role="status">↻ {comingBackDescription}</p>
          : agent && (agent.state === "running" || agent.state === "starting") && (
          <p class="working" aria-label="Working"><span class="spinner" /></p>
        )}
      </div>
      {subagent.value && (
        <SubagentSteps store={store} item={agent?.background?.find((b) => b.id === subagent.value!.id) ?? subagent.value} close={() => (subagent.value = null)} />
      )}
      </ViewLayerContext.Provider>
      </CallActionsContext.Provider>
      {/* As JumpToEnd: shown whenever the reader is away from the end; what came since, or a question
          waiting above or below, said in words (#973). */}
      {(away.value || newBelow.value || questionWaiting) && (
        <button class={`jump${newBelow.value || questionWaiting ? " news" : ""}`} onClick={questionWaiting ? toQuestion : toEnd}
          title={questionWaiting ? `Go to the question waiting ${questionAbove ? "above" : "below"}`
            : newBelow.value ? "Go to the end, where something new is" : "Go to the end"}
          aria-label={questionWaiting ? `Go to the question waiting ${questionAbove ? "above" : "below"} in the conversation`
            : newBelow.value ? "Go to the end of the conversation, where something new is" : "Go to the end of the conversation"}>
          <span aria-hidden="true">{questionAbove ? "↑" : "↓"}</span>{questionWaiting ? " Question waiting" : newBelow.value && " Something new"}
        </button>
      )}
      <footer class="foot">
        <BackgroundRows store={store} host={host} agent={agent} disabled={down} steps={(item) => (subagent.value = item)} />
        {agent && <Capsules store={store} host={host} agent={agent} />}
        <Prompt store={store} draftKey={`${host}|${session}`} placeholder={promptPlaceholder(agent)} disabled={(down && !keeps) || !agent}
          stop={agent && hasTurnInFlight(agent) ? () => void store.perform(host, agent.id, "agents/stop") : undefined}
          acting={agent && store.onItsWay.value[agent.id]}
          queues={willQueue(agent)} suggestion={agent?.suggestedPrompts?.[0]}
          banner={agent && <CostLimitBanner agent={agent} costs={store.costs.value[host]}
            goOn={() => void store.letAgentGoOn(host, agent)} />}
          recipient={store.recipient(host)}
          capabilities={agent ? store.account(host, agent.runtimeID)?.promptCapabilities : undefined}
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
              {r.project && <Labels store={store} host={host} agent={agent} folder={r.project} disabled={down} />}
            </>
          )}
          runtime={agent && <RuntimeLabel store={store} host={host} runtimeID={agent.runtimeID} />}>
          {agent && (
          <PromptMenus options={drawable(agent.advertisedOptions, [])} disabled={down} runtime={runtimeNameOn(store, host, agent.runtimeID)}
              value={(o) => store.pendingOptions.value[agent.id]?.[o.id] ?? agent.startOptions.values[o.id] ?? o.currentValue}
              onChange={(o, v) => void store.setOption(host, agent.id, o.id, v)}
              trailing={<ContextMeter agent={agent} costs={store.costs.value[host]} />}
              besideMode={<SandboxCapsule runtimeID={agent.runtimeID} override={agent.sandboxOverride}
                runtimeDefault={store.sandboxDefaults.value[host]?.[agent.runtimeID] ?? "runtime"}
                mode={typeof agent.startOptions.values.mode === "string" ? agent.startOptions.values.mode : undefined} disabled={down}
                onChange={(choice) => void store.setAgentSandbox(host, agent.id, choice)} />} />
          )}
        </Prompt>
      </footer>
    </section>
  );
}

/**
 * Where it works (PromptBar's placeTitle): its worktree, else the project folder's branch. Said,
 * not offered: moving a session to another worktree is the window's.
 */
function Place({ store, host, agent }: { store: Store; host: string; agent: Agent }) {
  const branch = useSignal<string | undefined>(undefined);
  const folder = projectFolder(agent);
  useEffect(() => {
    branch.value = undefined;
    if (agent.worktree) return;
    void store.worktrees(host, folder).then((list) => {
      branch.value = list?.worktrees.find((w) => w.isProjectFolder)?.branch;
    });
  }, [host, folder, agent.worktree?.root]);
  const title = agent.worktree?.name ?? branch.value ?? "Project folder";
  const help = agent.worktree ? `Worktree ${agent.worktree.name}${agent.worktree.branch ? ` on ${agent.worktree.branch}` : ""}` : "The project folder";
  return <span class="pill place" title={help} aria-label={`Works in: ${title}`}>{title}</span>;
}

/** The runtime the conversation is on (PromptBar's runtimeLabel): said, not offered. */
function runtimeNameOn(store: Store, host: string, runtimeID: string): string {
  return (store.runtimes.value[host] ?? []).find((r) => r.runtime.id === runtimeID)?.runtime.name ?? runtimeID;
}

function RuntimeLabel({ store, host, runtimeID }: { store: Store; host: string; runtimeID: string }) {
  const name = runtimeNameOn(store, host, runtimeID);
  return <span class="pill" title="Runtime" aria-label={`Runtime: ${name}`}>{name}</span>;
}

/**
 * Something typed while the agent worked, where it will appear (QueuedPromptRow), removable, and
 * with Send now while a turn runs on a runtime that takes words mid-turn.
 */
function Queued({ store, host, agent, disabled }: { store: Store; host: string; agent: Agent; disabled: boolean }) {
  const canSendNow = (agent.state === "running" || agent.state === "waitingOnUser")
    && store.account(host, agent.runtimeID)?.canSteer === true;
  // Held while anything is on its way to this agent; the one going, said (#87).
  const acting = store.onItsWay.value[agent.id];
  return (
    <>
      {(agent.queuedPrompts ?? []).map((queued) => {
        const going = typeof acting === "object" && acting.sendNow === queued.id;
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
 * What the open agent holds and waits for, and the events it waits on, over the prompt (036,
 * 042; LeaseRow and WaitCapsule, #254): one capsule each, and that sending takes a wait's place.
 */
function Capsules({ store, host, agent }: { store: Store; host: string; agent: Agent }) {
  const title = (id: string) => store.agent(host, id)?.title;
  const leases = leaseMark(agent.id, store.leases.value[host], title);
  const wait = eventWaitCapsule(agent, title);
  if (!leases && !wait) return null;
  return (
    <div class="capsules">
      {leases && (
        <p class="capsule-row" role="note" aria-label={leases.full}>
          {leases.capsules.map((text) => <span key={text} class="capsule" title={leases.full}>{text}</span>)}
        </p>
      )}
      {wait && (
        <>
          <p class="capsule-row"><span class="capsule" title={wait.line}>{wait.line}</span></p>
          <p class="faint small hint">{wait.hint}</p>
        </>
      )}
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
  const steps = useMemo(() => display(store.entries.value, item.id), [store.entries.value, item.id]);
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
        {/* Thinking too, each a folded line (#1315). */}
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

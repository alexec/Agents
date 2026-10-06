// The chosen session's chat (071 US2, FR-023): concise turns at the chosen level (069), tool
// calls, plans and background tasks (057), live from agent/entry and agent/changed; the cards
// above the prompt; the prompt pinned to the foot at every width (US6 scenario 4), with where
// the session works, its labels and its runtime over it, as in the window (#108). Long
// conversations come a page at a time as the top is reached, and the pane follows the end
// unless the person has scrolled up.
import { useSignal } from "@preact/signals";
import { useEffect, useLayoutEffect, useMemo, useRef } from "preact/hooks";
import { openTurnsHeld, rememberOpen, type Store } from "../model/store";
import { backgroundAge, backgroundEnded, backgroundNoun, isRunning } from "../model/background";
import { display, isPersonsAsk, isWorking, type ChatTurn, type Item } from "../model/turns";
import { toWireDate } from "../protocol/dates";
import type { Agent, AppViewCall, TranscriptEntry } from "../protocol/generated";
import { replace, route } from "../route";
import { Cards } from "./Cards";
import { OfflineStrip } from "./OfflineStrip";
import { FolderGoneNotice, MissingFolderStrip } from "./MissingFolder";
import { BlockStrip } from "./BlockStrip";
import { Telling } from "./Telling";
import { Labels } from "./Labels";
import { Prompt } from "./Prompt";
import { PromptMenus } from "./PromptMenus";
import { ContextMeter, CostLimitBanner, SandboxCapsule } from "./PromptStatus";
import { SessionMenu } from "./SessionMenu";
import { drawable } from "../model/options";
import { projectFolder } from "../model/groups";
import { CallActionsContext, detailSummaries, detailTitles, TurnView, type CallActions, type TurnDetail } from "./chat/Rows";
import { setPane } from "./files/paneState";
import { focusedEntry } from "../model/focus";
import { ViewLayerContext } from "./chat/AppView";
import { viewPin } from "./chat/appViewBridge";
import { ViewLayer, type ViewActions } from "./chat/viewLayer";
import { BackToList } from "./BackToList";
import { comingBackDescription } from "../model/status";
import { parkLine } from "./SessionRow";
import { hasTurnInFlight, promptPlaceholder, willQueue } from "../model/promptWords";
import { eventWaitCapsule, leaseMark } from "../model/rowLines";

const detailKey = "agents.turnDetail";

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

function savedDetail(): TurnDetail {
  const saved = localStorage.getItem(detailKey);
  return saved === "steps" || saved === "details" ? saved : "outcome";
}

/** The level every turn starts at, the page's one setting (View ▸ Turns in the window). */
const defaultDetail = { value: savedDetail() };

/** How close to an edge counts as being at it. Two numbers, so following does not flicker. */
const leftTheEnd = 160;
const atTheEnd = 40;

export function Chat({ store, host, session, down: linkDown }: { store: Store; host: string; session: string; down: boolean }) {
  // An offline host is the link down for this chat alone: read what was last heard, send nothing.
  const hostDown = !linkDown && !store.hostIsOnline(host);
  const down = linkDown || hostDown;
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
  // Not held: perhaps retired, and then its page says who it was (051, #253).
  useEffect(() => { if (!store.agent(host, session)) void store.lookUpRetired(host, session); }, [host, session]);
  const level = useSignal<TurnDetail>(defaultDetail.value);
  /** Turns opened or closed by hand, kept until the chat is left. */
  const chosen = useSignal<Record<string, TurnDetail>>({});
  /** The few opened turns whose entries are held, newest last (#291). */
  const fetched = useSignal<Record<string, HeldTurn>>({});
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
    };
  }, [session, agent?.pendingSandboxFailure, down]);

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
    };
    return { layer, actions };
  }, [layer, host, session, pinFolder]);
  useEffect(() => () => { void layer.tearDownAll("The conversation was closed."); }, [layer, host, session]);
  useEffect(() => () => layer.stop(), [layer]);
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

  useEffect(() => {
    // Whether its runtime takes words mid-turn, or pictures, is known once it has run.
    void store.loadRuntimes(host);
    chosen.value = {};
    fetched.value = {};
    openedTurns.current = [];
    following.current = true;
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
  useLayoutEffect(() => {
    const el = scroller.current;
    if (!el) return;
    const watcher = new ResizeObserver(() => {
      if (following.current && !loadingEarlier.current) el.scrollTop = el.scrollHeight;
    });
    watcher.observe(el);
    for (const child of Array.from(el.children)) watcher.observe(child);
    return () => watcher.disconnect();
  }, [rows.length]);

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
    if (!loadingEarlier.current) {
      if (fromBottom > leftTheEnd) follow(false);
      if (fromBottom < atTheEnd) {
        follow(true);
        newBelow.value = false;
      }
    }
    if (el.scrollTop < 400) void earlier();
  };

  // Asked for from Exchanged. A message is drawn with its entry's id. Being sent to one
  // is being sent away from the end, or the pane would scroll straight back off it.
  const focus = focusedEntry.value;
  useLayoutEffect(() => {
    if (!focus) return;
    const root = scroller.current;
    const mark = root && [...root.querySelectorAll("[data-entry]")].find((el) => el.getAttribute("data-entry") === focus);
    const target = mark && getComputedStyle(mark).display === "contents" ? mark.firstElementChild ?? mark : mark;
    if (target) {
      follow(false);
      target.scrollIntoView({ block: "center", behavior: "smooth" });
      focusedEntry.value = null;
      return;
    }
    const turn = rows.find((item) => item.ask?.id === focus || item.items.some((part) => part.id === focus));
    if (turn && (chosen.value[turn.id] ?? level.value) === "outcome") {
      follow(false);
      chosen.value = { ...chosen.value, [turn.id]: "steps" };
    }
  }, [focus, rows, level.value, chosen.value]);

  const toEnd = () => {
    const el = scroller.current;
    follow(true);
    newBelow.value = false;
    if (el) el.scrollTo({ top: el.scrollHeight, behavior: "smooth" });
  };

  const toggle = (turn: ChatTurn) => {
    const now = chosen.value[turn.id] ?? level.value;
    const open = level.value !== "outcome" ? level.value : "steps";
    chosen.value = { ...chosen.value, [turn.id]: now !== "outcome" ? "outcome" : open };
  };

  // A turn closed, or the level put back to outcome, lets its entries go (#291).
  useEffect(() => {
    const openNow = new Set<string>();
    for (const turn of rows) if ((chosen.value[turn.id] ?? level.value) !== "outcome") openNow.add(turn.id);
    const drop = openedTurns.current.filter((id) => !openNow.has(id));
    if (!drop.length) return;
    const next = { ...fetched.peek() };
    let changed = false;
    for (const id of drop) if (id in next) { delete next[id]; changed = true; }
    openedTurns.current = openedTurns.current.filter((id) => openNow.has(id));
    if (changed) fetched.value = next;
  }, [rows, chosen.value, level.value]);

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

  const choose = (detail: TurnDetail) => {
    level.value = detail;
    defaultDetail.value = detail;
    localStorage.setItem(detailKey, detail);
    chosen.value = {};
  };

  return (
    <section class="chat" aria-label="Chat" ref={chatColumn}>
      <header class="column-head">
        <BackToList />
        <h1>{agent?.title ?? "New session"}</h1>
        <span class="actions">
          <select class="detail" aria-label="Turns" title={detailSummaries[level.value]} value={level.value}
            onChange={(e) => choose((e.currentTarget as HTMLSelectElement).value as TurnDetail)}>
            {(["outcome", "steps", "details"] as const).map((d) => (
              <option key={d} value={d} title={detailSummaries[d]}>{detailTitles[d]}</option>
            ))}
          </select>
          <button onClick={() => replace({ ...r, files: !r.files })} aria-pressed={!!r.files}>Files</button>
          <SessionMenu store={store} host={host} agent={agent} disabled={down} />
        </span>
      </header>
      {hostDown && <OfflineStrip store={store} host={host} />}
      <FolderGoneNotice store={store} host={host} agent={agent} />
      <MissingFolderStrip store={store} host={host} agent={agent} />
      {/* Why a parked chat is parked, and since when, as the window's strip says it (040, #253). */}
      {agent && parkLine(agent) && <p class="park-strip quiet" role="status">{parkLine(agent)}</p>}
      <BlockStrip store={store} host={host} agent={agent} disabled={down} />
      <CallActionsContext.Provider value={callActions}>
      <ViewLayerContext.Provider value={viewHosting}>
      <div class="scroll transcript" ref={scroller} onScroll={onScroll}>
        <div class="view-layer" ref={(el) => { layer.element = el; }} />
        {store.hasMoreOfTheConversation && <p class="more" aria-label="Loading earlier"><span class="spinner" /></p>}
        {rows.map((turn, index) => (
          <TurnView key={turn.id} turn={turn} detail={chosen.value[turn.id] ?? level.value}
            fetched={fetched.value[turn.id]?.items} hasEarlier={fetched.value[turn.id]?.hasEarlier ?? false}
            auto={index >= rows.length - openTurnsHeld}
            isLive={index === rows.length - 1 && live} background={background}
            toggle={turnActions.toggle} loadDetail={turnActions.loadDetail} loadEarlier={turnActions.loadEarlier} />
        ))}
        {agent && <Queued store={store} host={host} agent={agent} disabled={down} />}
        {/* Live, at the foot: what the row says, until the prompt lands (ChatTranscript, #251). */}
        {agent && store.isComingBack(host, agent.id) ? <p class="working coming-back" role="status">↻ {comingBackDescription}</p>
          : agent && (agent.state === "running" || agent.state === "starting") && (
          <p class="working" aria-label="Working"><span class="spinner" /></p>
        )}
      </div>
      </ViewLayerContext.Provider>
      </CallActionsContext.Provider>
      {/* As JumpToEnd: shown whenever the reader is away from the end; what came since, said in words. */}
      {(away.value || newBelow.value) && (
        <button class={`jump${newBelow.value ? " news" : ""}`} onClick={toEnd}
          title={newBelow.value ? "Go to the end, where something new is" : "Go to the end"}
          aria-label={newBelow.value ? "Go to the end of the conversation, where something new is" : "Go to the end of the conversation"}>
          <span aria-hidden="true">↓</span>{newBelow.value && " Something new"}
        </button>
      )}
      <footer class="foot">
        <BackgroundRows store={store} host={host} agent={agent} disabled={down} />
        {agent && <Capsules store={store} host={host} agent={agent} />}
        <Cards store={store} host={host} session={session} down={down} />
        <Prompt store={store} draftKey={`${host}|${session}`} placeholder={promptPlaceholder(agent)} disabled={down || !agent}
          stop={agent && hasTurnInFlight(agent) ? () => void store.perform(host, agent.id, "agents/stop") : undefined}
          queues={willQueue(agent)} suggestion={agent?.suggestedPrompts?.[0]}
          banner={agent && <CostLimitBanner agent={agent} costs={store.costs.value[host]}
            goOn={() => void store.letAgentGoOn(host, agent)} />}
          recipient={store.recipient(host)}
          capabilities={agent ? store.account(host, agent.runtimeID)?.promptCapabilities : undefined}
          send={(text, attachments) => store.prompt(host, session, text, attachments)}
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
          <PromptMenus options={drawable(agent.advertisedOptions, [])} disabled={down}
              value={(o) => store.pendingOptions.value[agent.id]?.[o.id] ?? agent.startOptions.values[o.id] ?? o.currentValue}
              onChange={(o, v) => void store.setOption(host, agent.id, o.id, v)}
              trailing={<ContextMeter agent={agent} />}
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
function RuntimeLabel({ store, host, runtimeID }: { store: Store; host: string; runtimeID: string }) {
  const name = (store.runtimes.value[host] ?? []).find((r) => r.runtime.id === runtimeID)?.runtime.name ?? runtimeID;
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
          <div class="queued-bubble" role="group" aria-label={`Queued: ${queued.text}`}>
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
 * What the agent left running, over the prompt (057): Stop on what the runtime can stop, and a
 * subagent says it stops with the agent, as BackgroundItemRow (#253).
 */
function BackgroundRows({ store, host, agent, disabled }: { store: Store; host: string; agent: Agent | undefined; disabled: boolean }) {
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

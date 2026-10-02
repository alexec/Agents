// The chosen session's chat (071 US2, FR-023): concise turns at the chosen level (069), tool
// calls, plans and background tasks (057), live from agent/entry and agent/changed; the cards
// above the prompt; the prompt pinned to the foot at every width (US6 scenario 4). Long
// conversations come a page at a time as the top is reached, and the pane follows the end
// unless the person has scrolled up.
import { useSignal } from "@preact/signals";
import { useEffect, useLayoutEffect, useRef } from "preact/hooks";
import type { Store } from "../model/store";
import { backgroundAge, backgroundEnded, backgroundNoun, isRunning } from "../model/background";
import { display, isPersonsAsk, isWorking, storedTurn, turns, type ChatTurn, type Item } from "../model/turns";
import { toWireDate } from "../protocol/dates";
import type { Agent } from "../protocol/generated";
import { go, replace, route } from "../route";
import { Cards } from "./Cards";
import { Labels } from "./Labels";
import { Prompt } from "./Prompt";
import { PromptMenus } from "./PromptMenus";
import { SessionMenu } from "./SessionMenu";
import { drawable } from "../model/options";
import { detailSummaries, detailTitles, TurnView, type TurnDetail } from "./chat/Rows";

const detailKey = "agents.turnDetail";

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
  const project = r.project ? (store.projects.value[host] ?? []).find((p) => p.project.folder === r.project) : undefined;
  const level = useSignal<TurnDetail>(defaultDetail.value);
  /** Turns opened or closed by hand, kept until the chat is left. */
  const chosen = useSignal<Record<string, TurnDetail>>({});
  const fetched = useSignal<Record<string, Item[]>>({});
  const newBelow = useSignal(false);

  const rows: ChatTurn[] = [...store.turns.value.map(storedTurn), ...turns(store.items.value)];
  const background = agent?.background ?? [];
  const live = agent ? isWorking(agent.state) : false;

  const scroller = useRef<HTMLDivElement>(null);
  const following = useRef(true);
  const loadingEarlier = useRef(false);
  const settled = useRef(false);

  useEffect(() => {
    // Whether its runtime takes words mid-turn, or pictures, is known once it has run.
    void store.loadRuntimes(host);
    chosen.value = {};
    fetched.value = {};
    following.current = true;
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
      if (fromBottom > leftTheEnd) following.current = false;
      if (fromBottom < atTheEnd) {
        following.current = true;
        newBelow.value = false;
      }
    }
    if (el.scrollTop < 400) void earlier();
  };

  const toEnd = () => {
    const el = scroller.current;
    following.current = true;
    newBelow.value = false;
    if (el) el.scrollTo({ top: el.scrollHeight, behavior: "smooth" });
  };

  const toggle = (turn: ChatTurn) => {
    const now = chosen.value[turn.id] ?? level.value;
    const open = level.value !== "outcome" ? level.value : "steps";
    chosen.value = { ...chosen.value, [turn.id]: now !== "outcome" ? "outcome" : open };
  };

  const loadDetail = async (turn: ChatTurn) => {
    if (!turn.range || fetched.value[turn.id]) return;
    const items = display(await store.turnEntries(host, session, turn.range));
    fetched.value = { ...fetched.value, [turn.id]: items[0] && isPersonsAsk(items[0]) ? items.slice(1) : items };
  };

  const choose = (detail: TurnDetail) => {
    level.value = detail;
    defaultDetail.value = detail;
    localStorage.setItem(detailKey, detail);
    chosen.value = {};
  };

  return (
    <section class="chat" aria-label="Chat">
      <header class="column-head">
        <button class="back narrow-only" onClick={() => go({ host: r.host, project: r.project })}>‹ {project?.name ?? "Sessions"}</button>
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
      {hostDown && <p class="offline-strip" role="status">This host is offline. What's shown is from when it was last heard; nothing can be sent until it's back.</p>}
      {agent && r.project && <Labels store={store} host={host} agent={agent} folder={r.project} disabled={down} />}
      <div class="scroll transcript" ref={scroller} onScroll={onScroll}>
        {store.hasMoreOfTheConversation && <p class="more" aria-label="Loading earlier"><span class="spinner" /></p>}
        {rows.map((turn, index) => (
          <TurnView key={turn.id} turn={turn} detail={chosen.value[turn.id] ?? level.value} fetched={fetched.value[turn.id]}
            isLive={index === rows.length - 1 && live} background={background}
            toggle={() => toggle(turn)} loadDetail={() => void loadDetail(turn)} />
        ))}
        {agent && <Queued store={store} host={host} agent={agent} disabled={down} />}
        {agent && (agent.state === "running" || agent.state === "starting") && (
          <p class="working" aria-label="Working"><span class="spinner" /></p>
        )}
      </div>
      {newBelow.value && <button class="jump" onClick={toEnd}>New messages ↓</button>}
      <footer class="foot">
        <BackgroundRows agent={agent} />
        <Cards store={store} host={host} session={session} />
        <Prompt store={store} draftKey={`${host}|${session}`} placeholder="Reply…" disabled={down || !agent}
          capabilities={agent ? store.account(host, agent.runtimeID)?.promptCapabilities : undefined}
          send={(text, attachments) => store.prompt(host, session, text, attachments)}>
          {agent && (
            <PromptMenus options={drawable(agent.advertisedOptions, [])} disabled={down}
              value={(o) => store.pendingOptions.value[agent.id]?.[o.id] ?? agent.startOptions.values[o.id] ?? o.currentValue}
              onChange={(o, v) => void store.setOption(host, agent.id, o.id, v)} />
          )}
        </Prompt>
      </footer>
    </section>
  );
}

/**
 * Something typed while the agent worked, where it will appear (QueuedPromptRow), removable, and
 * with Send now while a turn runs on a runtime that takes words mid-turn.
 */
function Queued({ store, host, agent, disabled }: { store: Store; host: string; agent: Agent; disabled: boolean }) {
  const canSendNow = (agent.state === "running" || agent.state === "waitingOnUser")
    && store.account(host, agent.runtimeID)?.canSteer === true;
  return (
    <>
      {(agent.queuedPrompts ?? []).map((queued) => (
        <div key={queued.id} class="queued">
          <div class="queued-head">
            <p class="faint">Waiting its turn</p>
            {canSendNow && (
              <button class="link" disabled={disabled} title="Send this into the turn that is running, without waiting for it to end"
                onClick={() => void store.sendNow(host, agent.id, queued.id)}>↑ Send now</button>
            )}
            <button class="remove" aria-label="Remove queued prompt" title="Do not send this" disabled={disabled}
              onClick={() => void store.unqueue(host, agent.id, queued.id)}>×</button>
          </div>
          <p class="quiet">{queued.text}</p>
          {queued.attachments.length > 0 && <p class="faint small">📎 {queued.attachments.map((a) => a.displayName).join(", ")}</p>}
        </div>
      ))}
    </>
  );
}

/** What the agent left running, over the prompt (057). Stopping one is US3. */
function BackgroundRows({ agent }: { agent: Agent | undefined }) {
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
        <li key={item.id} title={item.command ?? item.detail ?? item.name}>
          <span class="noun">{backgroundNoun(item)}</span> {item.name}
          <span class="age">{backgroundEnded(item) ?? backgroundAge(item, now.value)}</span>
        </li>
      ))}
    </ul>
  );
}

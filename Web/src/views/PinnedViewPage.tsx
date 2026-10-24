// A pinned ui:// view's page (#189), in the chat's place, through the same view host a chat uses.
// No model called its tool, so the page makes the call itself each time it opens: the pin's
// feeding call, which the host allows only for a tool that changes nothing. The view hears
// tool-input, then tool-result when that call answers. It has no agent: what it would tell one
// is refused (viewLayer.ts). Our extension of MCP Apps (SEP-1865) (#188).
import { useSignal } from "@preact/signals";
import { useEffect, useLayoutEffect, useMemo, useRef } from "preact/hooks";
import type { Store } from "../model/store";
import { folderKey } from "../model/groups";
import { describe } from "../model/errors";
import type { JSONValue, PinView, UUID } from "../protocol/generated";
import { go } from "../route";
import { BackToList } from "./BackToList";
import { feedParams, pinnedViewCall, recipient } from "./chat/appViewBridge";
import { ViewLayer, type ViewActions } from "./chat/viewLayer";
import { ViewDiff } from "./chat/ViewDiff";
import { offerStart } from "./NewAgent";

/** Where this opening's feeding call is, for the call `id` it was made for. */
type Fed = { id: string } & ({ kind: "feeding" } | { kind: "fed"; answer: JSONValue } | { kind: "failed"; why: string });

export function PinnedViewPage({ store, host, folder, path, pin, down }: {
  store: Store; host: string; folder: string; path: string; pin: PinView | undefined; down: boolean;
}) {
  const view = pin?.view;
  const title = pin?.title ?? path;
  // A new place, a new view and a new call: each opening is fed afresh.
  const place = `${host}|${folderKey(folder)}|${path}`;
  const layer = useMemo(() => new ViewLayer(), [place]);
  const id = useMemo(() => crypto.randomUUID() as UUID, [place]);
  const fed = useSignal<Fed>({ id, kind: "feeding" });
  // Try Again and the link back make the feeding call again (#978).
  const attempt = useSignal(0);
  const actions = useMemo<ViewActions>(() => ({
    agentID: id,
    folder: folder,
    call: (method, params) => store.link.call(method, params as never, host) as Promise<unknown>,
    send: async () => false,
    // Its agents/start-agent opens the form in this folder, as it would from a chat (#834).
    startAgent: (start) => offerStart(store, host, folder, start),
    // Its agents/message-agent goes to the session on the branch, in this folder (#837).
    recipient: (message) => recipient(store.agents.value[host] ?? [], message, folder),
    sendTo: (agent, text) => store.prompt(host, agent, text, []),
  }), [id, host, folder, store]);
  const drawn = !!view && !pin?.missing;

  useEffect(() => {
    if (!view || pin?.missing) return;
    let gone = false;
    fed.value = { id, kind: "feeding" };
    store.link.call("views/call", feedParams(id, folder, view) as never, host)
      .then((answer) => { if (!gone) fed.value = { id, kind: "fed", answer: answer as JSONValue }; })
      .catch((error) => { if (!gone) fed.value = { id, kind: "failed", why: describe(error) }; });
    return () => { gone = true; };
  }, [id, JSON.stringify(view), pin?.missing, attempt.value]);
  useEffect(() => {
    const off = store.link.onState((state) => {
      if (state.kind !== "open") return;
      if (fed.peek().kind !== "fed") attempt.value += 1;
      layer.reconnected();
    });
    return () => { off(); };
  }, [layer, store]);

  // Another opening's answer is not this one's: until this call answers, it is feeding.
  const now: Fed = fed.value.id === id ? fed.value : { id, kind: "feeding" };
  const failed = now.kind === "failed";
  // A failed call's view is taken down; Try Again's answer draws a new one in its place.
  useEffect(() => { if (failed) void layer.tearDownAll("The view's call failed."); }, [layer, failed]);
  useEffect(() => () => { void layer.tearDownAll("The pinned view was closed."); }, [layer]);
  useEffect(() => () => layer.stop(), [layer]);
  const frame = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const box = frame.current;
    if (!view || !box || !drawn || failed) return;
    const call = pinnedViewCall(id, view, now.kind === "fed" ? now.answer : undefined);
    layer.scroller = box;
    layer.chat = box;
    layer.view(call, actions);
    layer.setFullscreen(call.id);
    layer.sync();
  });

  return (
    <section class="chat pinned-page" aria-label={title}>
      <header class="column-head"><BackToList />
        <div class="pin-head">
          <h1>{title}</h1>
          <span class="small quiet">{path}</span>
        </div>
        {/* A server's list view (#2032) is hidden, not unpinned. */}
        {pin && <button disabled={down} onClick={() => {
          void (pin.pinnedBy.kind === "server" ? store.setViewHidden(host, folder, path, true) : store.unpin(host, folder, path));
          go({ host, folder: folder, compose: true });
        }}>{pin.pinnedBy.kind === "server" ? "Hide" : "Unpin"}</button>}
      </header>
      {!pin ? (
        <p class="hint">{path} isn't pinned in this folder.</p>
      ) : pin.missing || !view ? (
        <p class="hint">{missingWords(pin)}</p>
      ) : now.kind === "failed" ? (
        <p class="hint">{title} can't be shown: {now.why}{" "}
          <button onClick={() => { attempt.value += 1; }}>Try Again</button></p>
      ) : (
        <div class="scroll view-host" ref={frame}>
          <ViewState layer={layer} id={id} />
          <div class="view-layer" ref={(el) => { layer.element = el; }} />
          <ViewDiff layer={layer} openLink={(url) => { window.open(url, "_blank", "noopener,noreferrer"); }} />
        </div>
      )}
    </section>
  );
}

/** What the page's view waits on or why it failed: a person's own server's view asks Show first (#191). */
function ViewState({ layer, id }: { layer: ViewLayer; id: string }) {
  void layer.made.value;
  const view = layer.find(id);
  if (!view) return null;
  const ask = view.ask.value;
  if (view.phase.value === "loading") return <p class="hint">Loading {view.title}…</p>;
  if (view.phase.value === "failed") {
    return <p class="hint">{view.failure.value}{" "}
      {view.canRetry.value && <button onClick={() => view.retry()}>Try Again</button>}</p>;
  }
  if (view.phase.value !== "asking" || !ask) return null;
  return (
    <div class="view-ask hint">
      <p>{ask.isNew ? `${ask.server} wants to show a view here.` : `${ask.server}'s view has changed since you said Show.`}</p>
      <p class="faint">It is drawn in a sandbox, and reaches only what it declared.</p>
      <p class="buttons">
        <button class="prominent" onClick={() => void view.answerShow(true)}>Show</button>
        <button onClick={() => void view.answerShow(false)}>Don't Show</button>
      </p>
    </div>
  );
}

function missingWords(pin: PinView): string {
  const why = pin.missingReason ?? "no such view";
  return `${pin.title} can't be shown on this machine: ${why}.`;
}

// A pinned ui:// view's page (#189), in the chat's place, through the same view host a chat uses.
// No model called its tool, so the page makes the call itself each time it opens: the pin's
// feeding call, which the host allows only for a tool that changes nothing. The view hears
// tool-input, then tool-result when that call answers. It has no agent: what it would tell one
// is refused (viewLayer.ts). Our extension of MCP Apps (SEP-1865), as the Dashboard is (#188).
import { useSignal } from "@preact/signals";
import { useEffect, useLayoutEffect, useMemo, useRef } from "preact/hooks";
import type { Store } from "../model/store";
import { folderKey } from "../model/groups";
import { describe } from "../model/errors";
import type { JSONValue, PinView, UUID } from "../protocol/generated";
import { go } from "../route";
import { BackToList } from "./BackToList";
import { feedParams, pinnedViewCall } from "./chat/appViewBridge";
import { ViewLayer, type ViewActions } from "./chat/viewLayer";

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
  const actions = useMemo<ViewActions>(() => ({
    agentID: id,
    project: folder,
    call: (method, params) => store.link.call(method, params as never, host) as Promise<unknown>,
    send: async () => false,
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
  }, [id, JSON.stringify(view), pin?.missing]);

  // Another opening's answer is not this one's: until this call answers, it is feeding.
  const now: Fed = fed.value.id === id ? fed.value : { id, kind: "feeding" };
  const failed = now.kind === "failed";
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
        {pin && <button disabled={down} onClick={() => { void store.unpin(host, folder, path); go({ host, project: folder, dashboard: true }); }}>Unpin</button>}
      </header>
      {!pin ? (
        <p class="hint">{path} isn't pinned in this project.</p>
      ) : pin.missing || !view ? (
        <p class="hint">{missingWords(pin)}</p>
      ) : now.kind === "failed" ? (
        <p class="hint">{title} can't be shown: {now.why}</p>
      ) : (
        <div class="scroll dashboard-host" ref={frame}>
          <ViewState layer={layer} id={id} />
          <div class="view-layer" ref={(el) => { layer.element = el; }} />
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
  if (view.phase.value === "failed") return <p class="hint">{view.failure.value}</p>;
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
  return `${pin.title} can't be shown on this host: ${why}.`;
}

// A tool's view, inline in the chat where its call began (#187), as an Object card (#5035). The card
// holds the view's place, its name and its ⋯; what it asks of the person is an Ask (#5031); the frame
// itself is the chat's ViewLayer's. Pin, when the host says the call can feed one, puts the view under
// the chat's folder (#189).
import { createContext } from "preact";
import { useContext, useLayoutEffect, useRef } from "preact/hooks";
import type { AppViewCall } from "../../protocol/generated";
import { canPin, viewTitle } from "./appViewBridge";
import type { HostedView, ViewActions, ViewLayer } from "./viewLayer";
import { Ask } from "../Ask";
import { ObjectCard } from "./ObjectCard";

export const ViewLayerContext = createContext<{ layer: ViewLayer; actions: ViewActions } | null>(null);

export function AppView({ call }: { call: AppViewCall }) {
  const hosting = useContext(ViewLayerContext);
  const slot = useRef<HTMLDivElement>(null);
  const view = hosting?.layer.view(call, hosting.actions);

  useLayoutEffect(() => {
    const element = slot.current;
    if (!hosting || !element) return;
    hosting.layer.attach(call.id, element);
    const watch = typeof ResizeObserver === "function" ? new ResizeObserver(() => hosting.layer.sync()) : null;
    watch?.observe(element);
    return () => { watch?.disconnect(); hosting.layer.detach(call.id, element); };
  }, [hosting, call.id]);

  if (!hosting || !view) {
    // Nowhere to draw it: what the model was told, as words.
    const text = (call.result as { content?: { type?: string; text?: string }[] } | undefined)?.content
      ?.flatMap((b) => (b.type === "text" && b.text ? [b.text] : [])).join("\n");
    return <div class="note"><p class="faint">{viewTitle(call.tool, call.server)}</p>{text && <p class="quiet">{text}</p>}</div>;
  }
  const full = hosting.layer.fullscreen.value === call.id;
  const result = resultText(call);
  const phase = view.phase.value;
  const canOpen = phase === "ready" && !full;
  const openFull = () => hosting.layer.setFullscreen(call.id);
  const more = [
    ...(canOpen ? [{ label: "Full Screen", title: "Show this view in the chat's place", run: openFull }] : []),
    ...(hosting.actions.pin && canPin(call) && !view.pinned.value
      ? [{ label: "Pin to Folder", title: "Pin this view under the folder", run: () => void view.pin() }] : []),
  ];
  const detail = ["View", call.state === "cancelled" ? "Cancelled" : null, view.pinned.value ? "Pinned" : null]
    .filter(Boolean).join(" · ");
  // The view is an Object card (#5035): the live view as its preview, then the row of its name, ⋯ (Full Screen,
  // Pin to Folder) and › (full screen). Only the row opens: the view takes its own clicks.
  return (
    <div class="app-view">
      <ObjectCard wide icon="layout-grid" title={view.title} detail={detail} more={more} tapAnywhere={false}
        open={canOpen ? openFull : undefined} openTitle="Show this view in the chat's place"
        preview={
          <div class="view-frame">
            {phase === "loading" && <p class="quiet">Loading {view.title}…</p>}
            {phase === "failed" && (
              <>
                <p class="quiet">{view.failure.value}{" "}
                  {view.canRetry.value && <button onClick={() => view.retry()}>Try Again</button>}
                </p>
                {result && <pre class="view-result">{result}</pre>}
              </>
            )}
            {/* Its Show / Don't Show is an Ask under "Waiting for you" (#5031): the card says one line. */}
            {phase === "asking" && view.ask.value && <p class="quiet">{viewWaitsWords}</p>}
            {phase === "gone" && <p class="quiet">This view was closed.</p>}
            {full && (
              <p class="quiet"><button class="plain" onClick={() => hosting.layer.setFullscreen(null)}>Showing full screen. Back to the chat</button></p>
            )}
            <div ref={slot} class="view-slot" style={{ height: full || phase !== "ready" ? 0 : `${view.height.value}px` }} />
          </div>
        } />
      {view.askedMessage.value !== null && <p class="quiet">{viewWaitsWords}</p>}
      {view.contextLine.value !== null && (
        <p class="view-context faint">
          With your next message the agent is told: {view.contextLine.value}{" "}
          <button class="plain" onClick={() => view.dropContext()}>Don't Tell</button>
        </p>
      )}
    </div>
  );
}

/** What a view's row says while its ask waits at the end of the chat. */
const viewWaitsWords = "Waiting for you, at the end of the chat.";

/** A view's ask (#191, #837), as an Ask (#5031): Show / Don't Show, or Send / Don't Send. */
export function ViewAsk({ view }: { view: HostedView }) {
  const ask = view.ask.value;
  if (view.phase.value === "asking" && ask) {
    const title = ask.isNew ? `Show the view “${view.title}”?` : `${ask.server}'s view has changed. Show it again?`;
    return (
      <Ask glyph="layout-grid" title={title} asker={ask.server} label={title}
        decline={<button class="link" onClick={() => void view.answerShow(false)}>Don't Show</button>}
        buttons={<button class="prominent" data-default="" onClick={() => void view.answerShow(true)}>Show</button>}>
        <p class="quiet small">It is drawn in a sandbox, and reaches only what it declared.</p>
      </Ask>
    );
  }
  const message = view.askedMessage.value;
  if (message === null) return null;
  const to = view.askedRecipient.value;
  const title = to ? `Send this to “${to.name}” as your message?` : "Send this as your message?";
  return (
    <Ask glyph="layout-grid" title={title} asker={view.title} label={title}
      decline={<button class="link" onClick={() => view.answerMessage(false)}>Don't Send</button>}
      buttons={<button class="prominent" data-default="" onClick={() => view.answerMessage(true)}>Send</button>}>
      <p>{message}</p>
    </Ask>
  );
}

function resultText(call: AppViewCall): string | null {
  const result = call.result as { content?: { type?: string; text?: string }[]; structuredContent?: unknown } | undefined;
  const content = result?.content?.flatMap((block) => block.type === "text" && block.text ? [block.text] : []).join("\n");
  if (content) return content;
  return result?.structuredContent === undefined ? null : JSON.stringify(result.structuredContent, null, 2) ?? null;
}

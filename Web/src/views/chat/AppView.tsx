// A tool's view, inline in the chat where its call began (#187). The row holds the view's place,
// its name and what it asks of the person; the frame itself is the chat's ViewLayer's. Pin, when
// the host says the call can feed one, puts the view under the chat's project (#189).
import { createContext } from "preact";
import { useContext, useLayoutEffect, useRef } from "preact/hooks";
import type { AppViewCall } from "../../protocol/generated";
import { canPin, viewTitle } from "./appViewBridge";
import type { ViewActions, ViewLayer } from "./viewLayer";

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
    return <div class="note"><p class="faint">{viewTitle(call.tool)}</p>{text && <p class="quiet">{text}</p>}</div>;
  }
  const full = hosting.layer.fullscreen.value === call.id;
  return (
    <div class="app-view">
      <p class="view-caption">
        <span class="faint">{view.title}</span>
        {call.state === "cancelled" && <span class="faint">Cancelled</span>}
        <span class="view-actions">
          {hosting.actions.pin && canPin(call) && (view.pinned.value
            ? <span class="faint">Pinned</span>
            : <button class="plain" title="Pin this view under the project" onClick={() => void view.pin()}>Pin</button>)}
          {view.phase.value === "ready" && !full && (
            <button class="plain" title="Show this view in the chat's place" onClick={() => hosting.layer.setFullscreen(call.id)}>
              Full screen
            </button>
          )}
        </span>
      </p>
      {view.phase.value === "failed" && <p class="quiet">{view.failure.value}</p>}
      {view.phase.value === "gone" && <p class="quiet">This view was closed.</p>}
      {full && (
        <p class="quiet"><button class="plain" onClick={() => hosting.layer.setFullscreen(null)}>Showing full screen. Back to the chat</button></p>
      )}
      <div ref={slot} class="view-slot" style={{ height: full || view.phase.value !== "ready" ? 0 : `${view.height.value}px` }} />
      {view.askedMessage.value !== null && (
        <div class="view-ask">
          <p class="faint">The view asks to send this as your message:</p>
          <p>{view.askedMessage.value}</p>
          <p class="buttons">
            <button class="prominent" onClick={() => view.answerMessage(true)}>Send</button>
            <button onClick={() => view.answerMessage(false)}>Don't Send</button>
          </p>
        </div>
      )}
      {view.contextLine.value !== null && (
        <p class="view-context faint">
          With your next message the agent is told: {view.contextLine.value}{" "}
          <button class="plain" onClick={() => view.dropContext()}>Don't Tell</button>
        </p>
      )}
    </div>
  );
}

// The Agent Browser (#3528, spike #3527; the window's AgentBrowserPane.swift), in its take-over tab (#4141): the browser on
// the session's machine, which agents drive, as a screencast from its host. The person sees each
// page as the agent does and can click, scroll, type and paste in it. Frames come only while the
// tab is on screen and the page is not hidden. The pane shows its own session's tab, and says when
// another session's agent holds the browser (#3916). On a touch screen a tap focuses a hidden field,
// so the keyboard opens inside the tap, as Safari asks; it closes when the host says the tap was not
// in a field that takes text (#4088, the Remote's #4091).
import { useSignal } from "@preact/signals";
import { useEffect, useRef } from "preact/hooks";
import type { Store } from "../model/store";
import type { BrowserInputRequest, BrowserNavigateAction, UUID } from "../protocol/generated";
import { describe } from "../model/errors";
import { keyInput, modifiers, otherHolder, pagePoint, stopped, touchTyped, words } from "../model/machineBrowser";
import { openAgentLink } from "../model/agentLink";

/** A key event with no name the page can take: the field's input event says what it typed. */
const unnamed = (e: KeyboardEvent) => e.isComposing || e.key === "Unidentified" || e.keyCode === 229;

export function AgentBrowserPane({ store, host, session }: { store: Store; host: string; session: string }) {
  const area = useRef<HTMLDivElement>(null);
  /** The hidden field a touch screen's keyboard types into (#4088). */
  const keys = useRef<HTMLTextAreaElement>(null);
  /** The newest press came from a finger, not a mouse or a pen. */
  const touch = useRef(false);
  const size = useSignal<{ width: number; height: number } | null>(null);
  const hidden = useSignal(document.hidden);
  const typed = useSignal("");
  const editing = useSignal(false);
  const problem = useSignal<string | null>(null);
  /** The person's input, sent one call at a time, in order; a move behind a move is replaced. */
  const outbox = useRef<BrowserInputRequest[]>([]);
  const sending = useRef(false);
  /** The button held, so a move while it is down is a drag. */
  const held = useRef<string | null>(null);
  /** The watch for this session has answered: until then, what the host said is another session's. */
  const answered = useSignal(false);

  const state = answered.value ? store.browserStates.value[host] ?? stopped : stopped;
  const heard = store.browserFrame.value;
  const frame = answered.value && heard?.host === host && state.status === "running" && !state.noTab ? heard.frame : null;
  const holder = otherHolder(state, session);

  useEffect(() => {
    const seen = () => { hidden.value = document.hidden; };
    document.addEventListener("visibilitychange", seen);
    return () => document.removeEventListener("visibilitychange", seen);
  }, []);

  useEffect(() => {
    const el = area.current;
    if (!el) return;
    const observer = new ResizeObserver(() => {
      const r = el.getBoundingClientRect();
      size.value = { width: Math.round(r.width), height: Math.round(r.height) };
    });
    observer.observe(el);
    return () => observer.disconnect();
  }, []);

  // A frame heard before this watch is another session's tab (#3916).
  useEffect(() => {
    if (store.browserFrame.peek()?.host === host) store.browserFrame.value = null;
  }, [host, session]);

  // Watch while shown and not hidden, at the area's size; a resize settles first.
  useEffect(() => {
    const s = size.value;
    if (hidden.value || !s || s.width <= 0 || s.height <= 0) return;
    let gone = false;
    const timer = setTimeout(() => {
      store.link.call("browser/watch", { width: s.width, height: s.height, agent: session as UUID }, host)
        .then((said) => {
          if (gone) return;
          store.browserStates.value = { ...store.browserStates.peek(), [host]: said };
          answered.value = true;
          problem.value = null;
        })
        .catch((error) => { if (!gone) problem.value = describe(error); });
    }, 250);
    return () => {
      gone = true;
      clearTimeout(timer);
    };
  }, [host, session, size.value?.width, size.value?.height, hidden.value]);
  useEffect(() => {
    if (hidden.value) return;
    return () => { void store.link.call("browser/unwatch", {}, host).catch(() => {}); };
  }, [host, session, hidden.value]);

  useEffect(() => { if (!editing.value) typed.value = state.url ?? ""; }, [state.url]);

  const drain = async () => {
    if (sending.current) return;
    sending.current = true;
    while (outbox.current.length > 0) {
      const next = outbox.current.shift()!;
      try {
        const said = await store.link.call("browser/input", next, host);
        problem.value = null;
        // A tap outside a field closes the keyboard; an older host says nothing, which keeps it.
        const field = keys.current;
        if (next.kind === "mouse" && next.type === "mouseReleased" && said?.editing === false
          && field && document.activeElement === field) {
          area.current?.focus({ preventScroll: true });
        }
      } catch (error) {
        // Input queued behind a failure is not sent later, out of context.
        outbox.current = [];
        problem.value = describe(error);
      }
    }
    sending.current = false;
  };
  const send = (input: BrowserInputRequest) => {
    if (state.status !== "running") return;
    const last = outbox.current[outbox.current.length - 1];
    if (input.kind === "mouse" && input.type === "mouseMoved" && last?.kind === "mouse" && last.type === "mouseMoved") {
      outbox.current[outbox.current.length - 1] = input;
    } else {
      outbox.current.push(input);
    }
    void drain();
  };
  const navigate = async (action: BrowserNavigateAction, url?: string) => {
    try {
      await store.link.call("browser/navigate", url === undefined ? { action } : { action, url }, host);
      problem.value = null;
    } catch (error) {
      problem.value = describe(error);
    }
  };

  const at = (e: MouseEvent): { x: number; y: number } | null => {
    const el = area.current;
    if (!el || !frame) return null;
    const r = el.getBoundingClientRect();
    return pagePoint({ x: e.clientX - r.left, y: e.clientY - r.top }, r, frame);
  };
  const button = (e: MouseEvent) => (e.button === 2 ? "right" : e.button === 1 ? "middle" : "left");
  const mouse = (e: MouseEvent, type: string, which: string | null) => {
    const p = at(e);
    if (!p) return;
    send({ kind: "mouse", type, x: p.x, y: p.y, button: which ?? "none",
      ...(type === "mouseMoved" ? {} : { clickCount: Math.max(e.detail, 1) }), modifiers: modifiers(e) });
  };

  const running = state.status === "running";
  return (
    <div class="agent-browser">
      <form class="agent-browser-bar" onSubmit={(e) => {
        e.preventDefault();
        const address = typed.value.trim();
        if (!address) return;
        editing.value = false;
        (e.currentTarget.querySelector("input") as HTMLInputElement | null)?.blur();
        void navigate("go", address);
      }}>
        <button type="button" class="link" title="Back" aria-label="Back" disabled={!running} onClick={() => void navigate("back")}>‹</button>
        <button type="button" class="link" title="Forward" aria-label="Forward" disabled={!running} onClick={() => void navigate("forward")}>›</button>
        <button type="button" class="link" title="Reload" aria-label="Reload" disabled={!running} onClick={() => void navigate("reload")}>↻</button>
        <input type="text" placeholder="Address" aria-label="Address" value={typed.value}
          onFocus={() => { editing.value = true; }} onBlur={() => { editing.value = false; }}
          onInput={(e) => { typed.value = (e.currentTarget as HTMLInputElement).value; }} />
      </form>
      {holder && <p class="agent-browser-holder small" role="status">
        <button type="button" class="link" title="Go to this session" onClick={() => openAgentLink(holder.id)}>{holder.title}</button> {words.using}
      </p>}
      <div ref={area} class="agent-browser-page" tabIndex={0} aria-label="The page in the machine's browser"
        onPointerDown={(e) => { touch.current = e.pointerType === "touch"; }}
        onMouseDown={(e) => {
          // Only a field focused inside the tap opens the keyboard; the host's answer comes too late.
          if (touch.current && keys.current) keys.current.focus({ preventScroll: true });
          else (e.currentTarget as HTMLDivElement).focus();
          held.current = button(e);
          mouse(e, "mousePressed", held.current);
          e.preventDefault();
        }}
        onMouseUp={(e) => { mouse(e, "mouseReleased", button(e)); held.current = null; }}
        onMouseMove={(e) => mouse(e, "mouseMoved", held.current)}
        onContextMenu={(e) => e.preventDefault()}
        onWheel={(e) => {
          const p = at(e);
          if (!p) return;
          e.preventDefault();
          // A line is about 40 CSS pixels, a page the view's height.
          const unit = e.deltaMode === 1 ? 40 : e.deltaMode === 2 ? (frame?.height ?? 600) : 1;
          send({ kind: "wheel", x: p.x, y: p.y, deltaX: e.deltaX * unit, deltaY: e.deltaY * unit, modifiers: modifiers(e) });
        }}
        onKeyDown={(e) => {
          // ⌘V and Ctrl+V are a paste: the paste event sends this computer's clipboard.
          if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "v") return;
          // Other ⌘ shortcuts stay the page's own (a new tab, a reload).
          if (e.metaKey) return;
          // A key the keyboard does not name (predictive text, a composition) comes as input.
          if (unnamed(e)) return;
          e.preventDefault();
          send(keyInput(e, true));
        }}
        onKeyUp={(e) => {
          if (e.metaKey || unnamed(e)) return;
          send(keyInput(e, false));
        }}
        onPaste={(e) => {
          const text = e.clipboardData?.getData("text/plain");
          e.preventDefault();
          if (text) send({ kind: "text", text });
        }}>
        <textarea ref={keys} class="agent-browser-keys" aria-hidden="true" tabIndex={-1}
          autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck={false}
          onInput={(e) => {
            const field = e.currentTarget as HTMLTextAreaElement;
            const typed = e as InputEvent;
            if (typed.isComposing) return;
            for (const input of touchTyped(typed.inputType, typed.data)) send(input);
            field.value = "";
          }}
          onCompositionEnd={(e) => {
            if (e.data) send({ kind: "text", text: e.data });
            (e.currentTarget as HTMLTextAreaElement).value = "";
          }} />
        {frame ? <img class="agent-browser-frame" alt="" draggable={false} src={`data:image/jpeg;base64,${frame.image}`} />
          : !answered.value ? <p class="hint"><span class="spinner" /> {words.loading}</p>
          : state.status === "running" && state.noTab ? <div class="agent-browser-note"><strong>{words.noTabTitle}</strong><p>{words.noTab}</p></div>
          : state.status === "running" ? <p class="hint"><span class="spinner" /> {words.loading}</p>
          : state.status === "starting" ? <p class="hint"><span class="spinner" /> {state.detail ?? words.starting}</p>
          : state.status === "failed" ? <div class="agent-browser-note"><strong>{words.failedTitle}</strong><p>{state.detail ?? words.failed}</p></div>
          : <div class="agent-browser-note"><strong>{words.stoppedTitle}</strong><p>{words.stopped}</p></div>}
      </div>
      {problem.value && <p class="faint small">{problem.value}</p>}
    </div>
  );
}

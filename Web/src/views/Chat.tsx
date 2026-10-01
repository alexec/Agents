// The chosen session's chat (071 US2): its entries, the cards above the prompt, and the prompt
// pinned to the foot at every width (US6 scenario 4). Phase 5 draws text only; turns, tool
// calls, cards and sending come in Phases 6 and 7.
import { useLayoutEffect, useRef } from "preact/hooks";
import type { Model } from "../model";
import type { TranscriptEntry } from "../protocol/generated";
import { go, replace, route } from "../route";

function text(entry: TranscriptEntry): { who: "person" | "agent"; text: string } | null {
  const kind = entry.kind as Record<string, Record<string, unknown>>;
  if (kind["userMessage"]) return { who: "person", text: String(kind["userMessage"]["_0"] ?? "") };
  if (kind["agentMessage"]) return { who: "agent", text: String(kind["agentMessage"]["text"] ?? "") };
  return null;
}

export function Chat({ model, host, session, down }: { model: Model; host: string; session: string; down: boolean }) {
  const r = route.value;
  const agent = model.agent(host, session);
  const project = r.project ? (model.projects.value[host] ?? []).find((p) => p.project.folder === r.project) : undefined;
  const lines = model.entries.value.map(text).filter((line): line is NonNullable<typeof line> => line !== null && line.text !== "");
  // Opens at the end and follows it, as the Mac window does, unless the person scrolled up.
  const scroller = useRef<HTMLDivElement>(null);
  const following = useRef(true);
  useLayoutEffect(() => { following.current = true; }, [session]);
  useLayoutEffect(() => {
    const el = scroller.current;
    if (el && following.current) el.scrollTop = el.scrollHeight;
  }, [lines.length, session]);
  // A narrower or wider window reflows the text; following stays at the end.
  useLayoutEffect(() => {
    const el = scroller.current;
    if (!el) return;
    const watcher = new ResizeObserver(() => {
      if (following.current) el.scrollTop = el.scrollHeight;
    });
    watcher.observe(el);
    return () => watcher.disconnect();
  }, []);
  return (
    <section class="chat" aria-label="Chat">
      <header class="column-head">
        <button class="back narrow-only" onClick={() => go({ host: r.host, project: r.project })}>‹ {project?.name ?? "Sessions"}</button>
        <h1>{agent?.title ?? "New session"}</h1>
        <span class="actions">
          <button onClick={() => replace({ ...r, files: !r.files })} aria-pressed={!!r.files}>Files</button>
          <button class="icon" aria-label="More" title="More" disabled>···</button>
        </span>
      </header>
      <div class="scroll transcript" ref={scroller} onScroll={(event) => {
        const el = event.currentTarget as HTMLDivElement;
        following.current = el.scrollHeight - el.scrollTop - el.clientHeight < 40;
      }}>
        {lines.map((line, index) => (
          <p key={index} class={line.who === "person" ? "bubble" : "reply"}>{line.text}</p>
        ))}
      </div>
      <footer class="foot">
        <div class="cards" aria-label="Waiting for you" />
        <div class="prompt">
          {/* Sending is US3 (T054); until then the prompt is drawn, and off. */}
          <textarea aria-label="Reply" placeholder="Reply…" disabled rows={2} data-down={down} />
          <div class="prompt-row">
            <button class="send" aria-label="Send" disabled>↑</button>
          </div>
        </div>
      </footer>
    </section>
  );
}

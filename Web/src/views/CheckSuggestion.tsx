// A suggestion of the read-only daily checks in For Review (#3331), as the window's and the Remote's
// CheckSuggestionRowLabel (Shared/UI/CheckSuggestionRow.swift): the mark, the title with its folder,
// the time and one grey line, the prompt Start sends. A press, or Start on hover, starts a session in
// its folder with that prompt and opens it; Dismiss, on hover and in its menu, takes it out for good.
import type { CheckSuggestion } from "../protocol/generated";
import type { Store } from "../model/store";
import { shortAgo } from "../model/activity";
import { fromWireDate } from "../protocol/dates";
import { go } from "../route";
import { holdForMenu, isMenuKey, openContextMenu, type MenuItem } from "./ContextMenu";

/** A suggestion's mark: a bulb, or a ring with a bang when it is urgent. */
export function SuggestionMark({ urgent }: { urgent: boolean }) {
  return (
    <span class={`sidebar-mark suggestion${urgent ? " urgent" : ""}`} aria-hidden="true">
      <svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.4"
        stroke-linejoin="round" stroke-linecap="round">
        {urgent
          ? <><circle cx="8" cy="8" r="6" /><path d="M8 4.8v3.8M8 11.2v.1" /></>
          : <><path d="M5.2 9.6A4 4 0 1 1 10.8 9.6c-.6.5-.8 1-.8 1.6H6c0-.6-.2-1.1-.8-1.6Z" /><path d="M6.3 13.2h3.4" /></>}
      </svg>
    </span>
  );
}

/** The prompt Start sends, on one line. */
export function suggestionLine(suggestion: CheckSuggestion): string {
  return suggestion.prompt.split(/\s+/).filter(Boolean).join(" ");
}

export function CheckSuggestionRow({ store, host, folder, suggestion, place, down }: {
  store: Store; host: string; folder: string; suggestion: CheckSuggestion; place: string; down: boolean;
}) {
  const at = fromWireDate(suggestion.at);
  const urgent = suggestion.urgent ?? false;
  const start = async () => {
    if (down) return;
    const session = await store.startSuggestion(host, folder, suggestion.id);
    if (session) go({ host, folder, session });
  };
  const dismiss = () => void store.dismissSuggestion(host, folder, suggestion.id);
  const menu = (): MenuItem[] => [
    { label: "Start Session", disabled: down, run: () => void start() },
    ...(suggestion.link ? [{ label: "Open Link", run: () => window.open(suggestion.link, "_blank", "noopener") }] : []),
    { label: "Dismiss", disabled: down, help: "Out of For Review for good", run: dismiss },
  ];
  return (
    <div class="nav-item check-suggestion">
      <button class="row session suggestion" disabled={down}
        aria-description={urgent ? "urgent suggestion of the daily checks" : "suggestion of the daily checks"}
        title={`${suggestion.title} · ${suggestionLine(suggestion)}`}
        onClick={() => void start()} onContextMenu={(e) => openContextMenu(e, menu())}
        onKeyDown={(e) => { if (isMenuKey(e)) openContextMenu(e, menu()); }} {...holdForMenu(menu)}>
        <SuggestionMark urgent={urgent} />
        <span class="body">
          <span class="title placed">
            <span class="name">{suggestion.title}</span>
            <span class="place"> {place}</span>
          </span>
          <span class="subtitle">{suggestionLine(suggestion)}</span>
        </span>
        <time class="when" dateTime={at.toISOString()} title={at.toLocaleString()}>{shortAgo(at)}</time>
      </button>
      <span class="actions">
        <button disabled={down} onClick={() => void start()} aria-label={`Start a session on ${suggestion.title}`}
          title="Start a session on this with its prompt">Start</button>
        <button disabled={down} onClick={dismiss} aria-label={`Dismiss ${suggestion.title}`}
          title="Take this suggestion out of For Review for good">Dismiss</button>
      </span>
    </div>
  );
}

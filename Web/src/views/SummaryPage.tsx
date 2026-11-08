// The Summary page (#3721): the daily summary's newest saved page, with the earlier ones in a picker,
// the session that wrote it one click away, and the daily summary's control under it, the same one
// Settings ▸ Agent Configuration ▸ Workflows has (#3351, #3395), as the Mac's and the Remote's
// SummaryPageView. Opened from the Summary row at the top of the sidebar. Links on the page open
// their session, pull request or issue (#3353), as the renderer draws them.
import { useEffect } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { Store } from "../model/store";
import type { SummaryPage as Page, SummaryPageText } from "../protocol/generated";
import { renderMarkdown } from "../render/markdown";
import { openAgentLink } from "../model/agentLink";
import { fromWireDate } from "../protocol/dates";
import { dailySummaryTimeLabel } from "../model/dailySummaryWords";
import { DailySummaryControl } from "./settings/DailySummary";
import { BackToList } from "./BackToList";

/** The row's line and the page's when no page is saved yet, as SummaryPageView.nonePage. */
export const nonePage = "No summary yet";

/** A page's place in the picker, such as "Fri 6 Nov, 18:10". */
export function summaryWhen(page: Page): string {
  const at = fromWireDate(page.savedAt);
  const day = at.toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short" });
  return `${day}, ${at.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" })}`;
}

export function SummaryPage({ store }: { store: Store }) {
  const pages = store.summaryPages.value;
  const chosen = useSignal<string | null>(null);
  const text = useSignal<SummaryPageText | null | "reading">("reading");
  const shown = pages.find((p) => p.name === chosen.value) ?? pages[0];
  // Read again when another page is picked or a new one is saved; reading the newest marks it read.
  useEffect(() => {
    if (!shown) { text.value = null; return; }
    let gone = false;
    if (text.peek() === "reading" || (text.peek() as SummaryPageText | null)?.page.name !== shown.name) text.value = "reading";
    void store.readSummaryPage(shown.name).then((read) => { if (!gone) text.value = read; });
    return () => { gone = true; };
  }, [shown?.name, shown?.savedAt]);
  const settings = store.dailySummary.value;
  const now = text.value;
  return (
    <section class="chat summary-page" aria-label="Summary">
      <header class="column-head"><BackToList />
        <div class="pin-head"><h1>Summary</h1></div>
        {pages.length > 1 && (
          <select aria-label="Page" value={shown?.name} onChange={(e) => (chosen.value = e.currentTarget.value)}>
            {pages.map((p) => <option key={p.name} value={p.name}>{summaryWhen(p)}</option>)}
          </select>
        )}
      </header>
      <div class="summary-body">
        {!shown ? (
          <p class="hint">{`${nonePage}. ${settings && settings.mode !== "off"
            ? `The first one is written at ${dailySummaryTimeLabel(settings.at)}.` : "Turn the daily summary on below."}`}</p>
        ) : now === "reading" ? (
          <p class="hint">Reading {shown.title}…</p>
        ) : now === null ? (
          <p class="hint">The summary could not be read.</p>
        ) : (
          <div class="markdown">{renderMarkdown(now.markdown)}</div>
        )}
        {shown?.writer && (
          <p><button class="link" onClick={() => openAgentLink(shown.writer!)}>How this was written</button></p>
        )}
        <hr />
        <DailySummaryControl store={store} />
      </div>
    </section>
  );
}

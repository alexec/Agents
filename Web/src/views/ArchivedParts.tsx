// The frame both Archived pages share (#4448, #4451), as the Mac's ArchivedPages.swift: the column head
// with Back, the title and the folder's name quiet after it, the filter, and the states (placeholder rows,
// empty, the stale strip, no match, the footer with Load more).
import type { ComponentChildren } from "preact";
import { loadingMore as loadingMoreWords, staleStrip, type ArchivedState } from "../model/archivedPage";
import { BackToList } from "./BackToList";
import { EmptyState, PlaceholderRows } from "./WorkParts";
import { MessageBanner } from "./MessageKinds";
import { Glyph } from "./Icon";

export function ArchivedFrame({ kind, title, folderName, filterLabel, filter, onFilter, state, empty, noMatch, children }: {
  kind: "sessions" | "workflows"; title: string; folderName: string; filterLabel: string;
  filter: string; onFilter: (words: string) => void; state: ArchivedState;
  empty: { mark: string; title: string; line: string }; noMatch: string; children: ComponentChildren;
}) {
  return (
    <section class={`chat archived-page ${kind}`} aria-label={`${folderName}: ${title}`}>
      <header class="column-head"><BackToList /><h1>{title}</h1><span class="quiet">{folderName}</span></header>
      <div class="scroll">
        <div class="archived-body">
          <input class="archived-filter" type="search" placeholder={filterLabel} aria-label={filterLabel} value={filter}
            onInput={(e) => onFilter((e.target as HTMLInputElement).value)} />
          {state.kind === "loading" ? <PlaceholderRows />
            : state.kind === "hostSilent" ? <div class="archived-middle"><StaleStrip /></div>
            : state.kind === "empty" ? (
              <div class="work-empty archived-middle">
                <Glyph of={empty.mark} class="archived-glyph" />
                <p class="strong">{empty.title}</p>
                <p class="quiet">{empty.line}</p>
              </div>
            )
            : state.kind === "noMatch" ? <div class="archived-middle"><EmptyState kind={kind} title={noMatch} action={{ words: "Clear", run: () => onFilter("") }} /></div>
            : <>
              {state.stale && <StaleStrip />}
              <div class={`archived-rows${state.stale ? " stale" : ""}`}>{children}</div>
            </>}
        </div>
      </div>
    </section>
  );
}

/** Its machine is not answering: over the rows last read, or alone with none. */
function StaleStrip() {
  return <MessageBanner tone="neutral" name="archived-stale">{staleStrip}</MessageBanner>;
}

/** The foot of an Archived page: how many, and Load more while the host has more; a spinner and
 *  "Loading more…" while it is asked. */
export function ArchivedFooter({ words, loadingMore, loadMore }: {
  words: string; loadingMore: boolean; loadMore?: (() => void) | undefined;
}) {
  return (
    <div class="archived-footer" aria-live="polite">
      {loadingMore ? <><span class="spinner" aria-hidden="true" /><span>{loadingMoreWords}</span></>
        : <><span>{words}</span>{loadMore && <button type="button" onClick={loadMore}>Load more</button>}</>}
    </div>
  );
}

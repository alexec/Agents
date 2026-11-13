// A folder's archived sessions (#495, #4451), from its Archived Sessions row in the sidebar, as the
// Mac's ArchivedSessionsPage: the sidebar's own rows, under a heading for each day they were archived,
// a filter that also asks the host with the words, and Load more at the foot. Each row opens its chat,
// with its menu (Unarchive among them).
import { useEffect, useRef, useState } from "preact/hooks";
import { days, footer, hasMore, nextLimit, pageSize, sessionsWords, archivedState, readAt } from "../model/archivedPage";
import { parseQuery, queryMatches } from "../model/labels";
import type { Store } from "../model/store";
import { route } from "../route";
import { ArchivedFooter, ArchivedFrame } from "./ArchivedParts";
import { SidebarSession } from "./Sidebar";

export function ArchivedSessionsPage({ store, host, folder, folderName, down, liveUntil }: {
  store: Store; host: string; folder: string; folderName: string; down: boolean;
  /** When the rows were last live with their host while it, or the link, is down (#5143). */
  liveUntil: number | undefined;
}) {
  const online = store.hostIsOnline(host);
  // Whether the host answered the ask for the archive: undefined while it is on its way, so an empty
  // list is not "none" before it is known (#664).
  const [answered, setAnswered] = useState<boolean | undefined>(undefined);
  // When the host last answered an ask of this page (#5143), for the stale strip's time.
  const [answeredAt, setAnsweredAt] = useState<number | undefined>(undefined);
  // The same for the filter's words.
  const [searched, setSearched] = useState<boolean | undefined>(undefined);
  const [filter, setFilter] = useState("");
  const [loadingMore, setLoadingMore] = useState(false);
  // The limit the page holds, which Load more raises; let go with it when the page closes.
  const limit = useRef(pageSize);
  const words = filter.trim();
  // Held while the page is open, and let go when it closes (#165).
  useEffect(() => {
    if (!online) return;
    let live = true;
    void store.loadArchived(host, folder, limit.current).then((said) => { if (!live) return; setAnswered(said); if (said) setAnsweredAt(Date.now()); });
    store.holdWorkflows(host, folder);
    return () => {
      live = false;
      // A session opened from here is watched before the page lets the rest go, so it stays.
      const next = route.peek();
      if (next.host === host && next.session) store.watch(host, next.session);
      store.unloadArchived(host, folder, limit.current);
      store.releaseWorkflows(host, folder);
    };
  }, [host, folder, online]);
  // The host too, for the words, so one older than the page held is found (#4448).
  useEffect(() => {
    if (!words || !online) return;
    setSearched(undefined);
    let live = true;
    const timer = setTimeout(() => {
      void store.searchArchived(host, folder, words).then((said) => { if (!live) return; setSearched(said); if (said) setAnsweredAt(Date.now()); });
    }, 250);
    return () => { live = false; clearTimeout(timer); };
  }, [host, folder, words, online]);

  const held = store.folderView(host, folder).archived;
  const query = words ? parseQuery(words) : undefined;
  const shown = query ? held.filter((agent) => queryMatches(query, agent)) : held;
  const state = archivedState(shown.length, !!words, words ? searched : answered, !online || down);
  const total = Math.max(store.folders.value[host]?.find((p) => p.folder.folder === folder)?.counts.archived ?? 0, held.length);
  const loadMore = () => {
    if (loadingMore) return;
    // The next limit is held before the last is let go, so the rows stay.
    const before = limit.current;
    limit.current = nextLimit(held.length);
    setLoadingMore(true);
    const asked = store.loadArchived(host, folder, limit.current);
    store.unloadArchived(host, folder, before);
    void asked.finally(() => setLoadingMore(false));
  };
  return (
    <ArchivedFrame kind="sessions" title={sessionsWords.title} folderName={folderName} filterLabel={sessionsWords.filter}
      filter={filter} onFilter={setFilter} state={state} readAt={readAt(liveUntil, answeredAt)} noMatch={sessionsWords.noMatch}
      empty={{ mark: "▣", title: sessionsWords.emptyTitle, line: sessionsWords.emptyLine }}>
      {days(shown).map((day) => (
        <div class="archived-day" key={day.id}>
          <h2 class="subhead">{day.title}</h2>
          {day.agents.map((agent) => (
            <SidebarSession key={agent.id} store={store} host={host} folder={folder} agent={agent} chosen={false}
              down={down || !online} archivedTime />
          ))}
        </div>
      ))}
      {!words && (
        <ArchivedFooter words={footer(held.length, total)} loadingMore={loadingMore}
          loadMore={hasMore(held.length, total) && online && !down ? loadMore : undefined} />
      )}
    </ArchivedFrame>
  );
}

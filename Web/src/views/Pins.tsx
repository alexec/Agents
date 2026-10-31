// A folder's pinned pages (#159), as the window has them: rows first in the folder's fold,
// dragged among themselves to re-order, and a page in the chat's place, live as the file
// changes. Markdown is the live page an agent's show_file opens. HTML is shown as its source,
// as the files pane shows it here: the page allows no frames and no HTML of its own making
// (its policy), which is what keeps what an agent wrote from running in it. The window and
// the Remote draw it. A pinned ui:// view (#189) is a row the same, and its page is
// PinnedViewPage's.
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { Store } from "../model/store";
import { folderKey } from "../model/groups";
import { describe } from "../model/errors";
import type { FileStamp, PinView } from "../protocol/generated";
import { go } from "../route";
import { fromWireDate } from "../protocol/dates";
import { holdForMenu, isMenuKey, openContextMenu, type MenuItem } from "./ContextMenu";
import { LiveDocument, type PageSource } from "./LiveDocument";
import { BackToList } from "./BackToList";
import { PinnedViewPage } from "./PinnedViewPage";

/** A screen with no pointer to hover: there a held finger opens the menu (#663), with its Move Up and
 *  Down, rather than lifting the row to drag it. */
function touchOnly(): boolean {
  return typeof matchMedia === "function" && matchMedia("(hover: none)").matches;
}

export function PinnedPageRows({ store, host, folder, chosen, down }: {
  store: Store; host: string; folder: string; chosen: string | undefined; down: boolean;
}) {
  const pins = store.pinsIn(host, folder);
  const dragged = useSignal<string | null>(null);
  if (pins.length === 0) return null;
  const paths = pins.map((p) => p.path);
  const arrange = (next: string[]) => { if (!down) void store.arrangePins(host, folder, next); };
  const step = (path: string, by: number) => {
    const next = [...paths];
    const index = next.indexOf(path);
    if (index < 0 || !next[index + by]) return;
    [next[index], next[index + by]] = [next[index + by]!, next[index]!];
    arrange(next);
  };
  const menu = (pin: PinView): MenuItem[] => [
    { label: "Open", run: () => go({ host, folder: folder, page: pin.path }) },
    { label: "Move Up", disabled: down || paths[0] === pin.path, run: () => step(pin.path, -1) },
    { label: "Move Down", disabled: down || paths[paths.length - 1] === pin.path, run: () => step(pin.path, 1) },
    { label: "Unpin", disabled: down, run: () => void store.unpin(host, folder, pin.path) },
  ];
  // A pin dropped on a pin goes before it; on the group's foot, last.
  const drop = (before: string | null) => (e: DragEvent) => {
    const what = dragged.value;
    if (!what) return;
    e.preventDefault();
    e.stopPropagation();
    dragged.value = null;
    if (what === before) return;
    const rest = paths.filter((p) => p !== what);
    const at = before === null ? rest.length : rest.indexOf(before);
    rest.splice(at < 0 ? rest.length : at, 0, what);
    arrange(rest);
  };
  const over = (e: DragEvent) => { if (dragged.value) e.preventDefault(); };
  return (
    <div class="group pins" role="group" aria-label="Pinned pages" onDragOver={over} onDrop={drop(null)}>
      {pins.map((pin) => (
        <div class="nav-item" key={pin.path} draggable={!down && !touchOnly()}
          onDragStart={(e) => { dragged.value = pin.path; e.dataTransfer?.setData("text/plain", pin.path); }}
          onDragEnd={() => (dragged.value = null)}
          onDragOver={over} onDrop={drop(pin.path)}
          onContextMenu={(e) => openContextMenu(e, menu(pin))}
          onKeyDown={(e) => { if (isMenuKey(e)) openContextMenu(e, menu(pin)); }} {...holdForMenu(() => menu(pin))}>
          <div class={`row pin${chosen === pin.path ? " chosen" : ""}${pin.missing ? " missing" : ""}${dragged.value === pin.path ? " dragging" : ""}`}>
            <button class="pick" aria-current={chosen === pin.path}
              title={pin.missing ? `Missing: ${pin.path}${pin.missingReason ? `: ${pin.missingReason}` : ""}` : pin.path}
              aria-description={pin.missing ? "missing" : undefined}
              onClick={() => go({ host, folder: folder, page: pin.path })}>
              <span class="pin-mark" aria-hidden="true">{pinMark(pin)}</span>
              {/* Nothing at its end, which is only a session's (#587): missing is the grey title and the tooltip. */}
              <span class="title">{pin.title}</span>
            </button>
          </div>
        </div>
      ))}
    </div>
  );
}

/** A connected server's list views (#2032), after the folder's pins: a row each, named by the service
 *  ("GitHub · Issues"), without a pin. Its menu hides one; the folder's menu shows them again. */
export function ServerViewRows({ store, host, folder, chosen, down }: {
  store: Store; host: string; folder: string; chosen: string | undefined; down: boolean;
}) {
  const views = store.serverViewsIn(host, folder).filter((v) => !v.hidden);
  if (views.length === 0) return null;
  const menu = (view: PinView): MenuItem[] => [
    { label: "Open", run: () => go({ host, folder: folder, page: view.path }) },
    { label: "Hide", disabled: down, help: "Take this view out of the sidebar; the folder's menu shows it again",
      run: () => void store.setViewHidden(host, folder, view.path, true) },
  ];
  return (
    <div class="group pins server-views" role="group" aria-label="Server views">
      {views.map((view) => (
        <div class="nav-item" key={view.path}
          onContextMenu={(e) => openContextMenu(e, menu(view))}
          onKeyDown={(e) => { if (isMenuKey(e)) openContextMenu(e, menu(view)); }} {...holdForMenu(() => menu(view))}>
          <div class={`row pin${chosen === view.path ? " chosen" : ""}`}>
            <button class="pick" aria-current={chosen === view.path} title={countTitle(view)}
              onClick={() => go({ host, folder: folder, page: view.path })}>
              <span class="pin-mark" aria-hidden="true">{pinMark(view)}</span>
              <span class="title">{view.title}</span>
              {/* Its server's count (#2033), grey as a fold's count. */}
              {view.count !== undefined && <span class="count">{view.count}</span>}
            </button>
          </div>
        </div>
      ))}
    </div>
  );
}

/** A view row's tooltip: its address, and when its count was read (#2033). */
function countTitle(view: PinView): string {
  if (view.count === undefined || view.countAt === undefined) return view.path;
  const when = fromWireDate(view.countAt).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  return `${view.path}\n${view.countStale ? `As of ${when}: the server did not answer since.` : `As of ${when}.`}`;
}

/** The folder menu's Show Hidden Views (#2032), or nothing when none is hidden. */
export function showHiddenViewsItem(store: Store, host: string, folder: string, down: boolean): MenuItem[] {
  const hidden = store.serverViewsIn(host, folder).filter((v) => v.hidden);
  if (hidden.length === 0) return [];
  return [{ label: `Show Hidden Views (${hidden.length})`, disabled: down, help: "Put this folder's hidden server views back in the sidebar",
    run: () => { for (const v of hidden) void store.setViewHidden(host, folder, v.path, false); } }];
}

function pinMark(pin: PinView): string {
  return pin.kind === "view" ? "◇" : pin.kind === "html" ? "◍" : "▤";
}

type Shown =
  | { kind: "reading" }
  | { kind: "html"; path: string; text: string; stamp: FileStamp }
  | { kind: "problem"; why: string };

export function PinnedPage({ store, host, folder, path, down }: {
  store: Store; host: string; folder: string; path: string; down: boolean;
}) {
  const pin = store.pinOrViewIn(host, folder, path);
  if (pin?.view || path.startsWith("ui://")) {
    return <PinnedViewPage store={store} host={host} folder={folder} path={path} pin={pin} down={down} />;
  }
  return <PinnedFilePage store={store} host={host} folder={folder} path={path} down={down} />;
}

function PinnedFilePage({ store, host, folder, path, down }: {
  store: Store; host: string; folder: string; path: string; down: boolean;
}) {
  const key = `${host}|${folderKey(folder)}`;
  const revision = store.pageRevisions.value[key] ?? 0;
  const pin = store.pinsIn(host, folder).find((p) => p.path === path);
  const isHTML = /\.html?$/i.test(path);
  const shown = useSignal<Shown>({ kind: "reading" });
  const title = pin?.title ?? path.split("/").pop() ?? path;
  const back = <BackToList />;

  const read = (file: string, stamp?: FileStamp) => store.readPage(host, folder, file, stamp);
  // HTML only: Markdown is LiveDocument's to read.
  useEffect(() => {
    if (!isHTML) return;
    let gone = false;
    void (async () => {
      try {
        const was = shown.peek();
        // The stamp held is this page's only: another page's would read as unchanged.
        const r = await read(path, was.kind === "html" && was.path === path ? was.stamp : undefined);
        if (gone || r.kind === "unchanged") return;
        if (r.kind !== "text") { shown.value = { kind: "problem", why: `${path} can't be shown as a page.` }; return; }
        shown.value = { kind: "html", path, text: r.text, stamp: r.stamp };
      } catch (error) {
        if (!gone) shown.value = { kind: "problem", why: missingWords(path, describe(error)) };
      }
    })();
    return () => { gone = true; };
  }, [host, folder, path, revision, pin?.missing]);

  const page: PageSource = {
    read: (stamp) => read(path, stamp),
    write: (written) => store.writePage(host, folder, path, written),
    watch: () => () => {},
    changed: revision,
  };
  const now = shown.value;
  return (
    <section class="chat pinned-page" aria-label={title}>
      <header class="column-head">{back}
        <div class="pin-head">
          <h1>{title}</h1>
          <span class="small quiet">{path}</span>
        </div>
        {pin
          ? <button disabled={down} onClick={() => { void store.unpin(host, folder, path); go({ host, folder: folder, compose: true }); }}>Unpin</button>
          : <button disabled={down || store.pinsIn(host, folder).length >= 10} onClick={() => void store.pin(host, folder, path)}
              title="Pin this page under the folder">Pin to Folder</button>}
      </header>
      {pin?.missing ? (
        <p class="hint">{missingWords(path, "")}</p>
      ) : !isHTML ? (
        <LiveDocument store={store} host={host} agentID="" path={path} source={page} />
      ) : now.kind === "problem" ? (
        <p class="hint">{now.why}</p>
      ) : now.kind === "reading" || now.path !== path ? (
        <p class="hint">Reading {path}…</p>
      ) : (
        <div class="page-source">
          <p class="quiet small">HTML is shown as its source here, so nothing in it runs. The Mac and the iPhone draw it as a page.</p>
          <pre>{now.text}</pre>
        </div>
      )}
    </section>
  );
}

function missingWords(path: string, why: string): string {
  return /is gone|isn't in|not there/.test(why) || why === ""
    ? `${path} isn't in the folder. It may have been moved or deleted, or be on a branch that hasn't landed.`
    : `${path} can't be read: ${why}`;
}

// A project's Dashboard (074), as the window has it: a row at the top of the sessions column, and
// a page in the chat's place with tiles in sections, small ones in a grid and tables and notes
// across. Greyed when stale, with Move, Hide, Show, Remove and the tile's detail behind its ···
// menu. Tiles drag within and between sections, and a section drags by its heading (#147).
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { Store } from "../model/store";
import { folderKey } from "../model/groups";
import {
  ageWords, agoWords, arrangement, canUpdate, change, changeWords, filesSentence, historyFile, isGood, isStale, isWide, keeperNote,
  moving, movingSection, neighbour, numberWords, rowDetail, sections, shownLevel, sparkline, stepping, updateLine,
} from "../model/dashboard";
import { isSafeLink, Markdown } from "../render/markdown";
import type { DashboardOrder, DashboardSnapshot, DashboardUpdate, TileCell, TileLink, TileView } from "../protocol/generated";
import { go } from "../route";
import { fromWireDate, toWireDate } from "../protocol/dates";

/** What is being dragged: a tile, by id, or a section, by its heading. In the page, not the
 *  DataTransfer, which a drop target can't read until the drop. */
type Dragged = { tile: string } | { section: string | null };

export function DashboardRow({ store, host, folder, chosen, onPick }: {
  store: Store; host: string; folder: string; chosen: boolean; onPick: () => void;
}) {
  const summary = store.dashboardSummaries.value[`${host}|${folderKey(folder)}`];
  return (
    <button class={`row dashboard-row${chosen ? " chosen" : ""}`} aria-current={chosen} onClick={onPick}>
      <span class="title">
        <span class="glyph" aria-hidden="true">▦</span> Dashboard
        {(summary?.bad ?? 0) > 0 && <span class="dot failure" aria-label="A tile needs a look" />}
      </span>
      <span class="subtitle">{rowDetail(summary)}</span>
    </button>
  );
}

export function DashboardPage({ store, host, folder, projectName, down }: {
  store: Store; host: string; folder: string; projectName: string; down: boolean;
}) {
  const key = `${host}|${folderKey(folder)}`;
  const revision = store.dashboardRevisions.value[key] ?? 0;
  const showsHidden = useSignal(false);
  const detail = useSignal<string | null>(null);
  useEffect(() => { void store.loadDashboard(host, folder); }, [host, folder, revision]);
  const snapshot = store.dashboards.value[key];
  const back = <button class="back narrow-only" onClick={() => go({ host, project: folder })}>‹ {projectName}</button>;
  const groups = snapshot ? sections(snapshot, showsHidden.value) : [];
  const newest = snapshot ? Math.max(...snapshot.tiles.map((t) => t.setAt ?? -Infinity)) : -Infinity;
  const hiddenCount = snapshot ? snapshot.tiles.filter((t) => t.tile?.hidden).length : 0;
  const opened = snapshot?.tiles.find((t) => t.id === detail.value);
  const dragged = useSignal<Dragged | null>(null);
  const arrange = (change: (order: DashboardOrder) => DashboardOrder | null) => {
    if (!snapshot || down) return;
    const order = change(arrangement(snapshot));
    if (order) void store.arrangeDashboard(host, folder, order);
  };
  // A tile dropped on a tile goes before it; on a section's empty space, at its end; a section
  // dropped on a heading goes before that section.
  const dropOn = (section: string | null, before?: string) => (e: DragEvent) => {
    const what = dragged.value;
    if (!what) return;
    e.preventDefault();
    e.stopPropagation();
    dragged.value = null;
    if ("tile" in what) {
      if (what.tile !== before) arrange((o) => moving(o, [what.tile], section, before));
    } else if (before === undefined && what.section !== section) {
      arrange((o) => movingSection(o, what.section, section));
    }
  };
  const over = (e: DragEvent) => { if (dragged.value) e.preventDefault(); };
  return (
    <section class="chat dashboard-page" aria-label="Dashboard">
      <header class="column-head">{back}<h1>Dashboard</h1>
        <label class="show-hidden small quiet">
          <input type="checkbox" checked={showsHidden.value}
            onChange={(e) => (showsHidden.value = (e.currentTarget as HTMLInputElement).checked)} />
          Show Hidden Tiles{hiddenCount > 0 ? ` (${hiddenCount})` : ""}
        </label>
        {snapshot?.update && <UpdateNow store={store} host={host} folder={folder} update={snapshot.update} down={down} />}
        {/* Starting an agent, from the project's own page (#151), as the window's toolbar has it. */}
        <button class="icon" aria-label="New session" title="Start a new session in this project" disabled={down}
          onClick={() => go({ host, project: folder, compose: true })}>✎</button>
      </header>
      <div class="scroll">
        <div class="dashboard-body">
          <p class="quiet">{projectName}{Number.isFinite(newest) && snapshot
            ? ` · updated ${agoWords(snapshot.now - newest)}` : " · kept by its agents"}</p>
          {snapshot?.update && <UpdateLine host={host} folder={folder} update={snapshot.update} />}
          {snapshot?.note && <p class="quiet small">⚠︎ {snapshot.note}</p>}
          {!snapshot && <p class="hint">Loading…</p>}
          {snapshot && groups.length === 0 && (
            <p class="hint">{hiddenCount > 0 ? "Every tile is hidden. Show Hidden Tiles brings them back."
              : "No tiles yet. Agents keep tiles here with set_tile: a number with its trend, a status, a table, a note or a link."}</p>
          )}
          {groups.map((section, index) => (
            <div class="tile-section" key={section.title ?? ""}>
              {section.title && (
                <h2 class="section-head" draggable={!down} title="Drag to move this section"
                  onDragStart={(e) => { dragged.value = { section: section.title }; e.dataTransfer?.setData("text/plain", section.title!); }}
                  onDragEnd={() => (dragged.value = null)}
                  onDragOver={over} onDrop={(e) => {
                    const what = dragged.value;
                    if (what && "section" in what) dropOn(section.title)(e);
                    else dropOn(section.title, section.tiles[0]?.id)(e);
                  }}>
                  {section.title}
                  <SectionMenu down={down} first={index === 0} last={index === groups.length - 1}
                    onUp={() => arrange((o) => movingSection(o, section.title, groups[index - 1]!.title))}
                    onDown={() => arrange((o) => movingSection(o, section.title,
                      index + 2 < groups.length ? groups[index + 2]!.title : undefined))} />
                </h2>
              )}
              <div class="tile-grid" onDragOver={over} onDrop={dropOn(section.title)}>
                {section.tiles.map((tile) => (
                  <Tile key={tile.id} store={store} host={host} folder={folder} tile={tile} now={snapshot!.now} down={down}
                    onDetail={() => (detail.value = tile.id)}
                    drag={{
                      start: () => (dragged.value = { tile: tile.id }),
                      end: () => (dragged.value = null),
                      over, drop: dropOn(section.title, tile.id),
                    }}
                    moves={moveItems(snapshot!, tile.id, showsHidden.value, groups, arrange)} />
                ))}
              </div>
            </div>
          ))}
          {/* The tiles are the project's files (#127), the window's words. */}
          {snapshot && <p class="quiet small">{filesSentence}.</p>}
          {opened && snapshot && <TileDetail tile={opened} now={snapshot.now} onClose={() => (detail.value = null)} />}
        </div>
      </div>
    </section>
  );
}

/** Update now (#146): Updating… while a run is going, off while it can't start. */
function UpdateNow({ store, host, folder, update, down }: {
  store: Store; host: string; folder: string; update: DashboardUpdate; down: boolean;
}) {
  // Ticks so the cooldown's end turns the button back on.
  const tick = useSignal(0);
  useEffect(() => { const timer = setInterval(() => (tick.value += 1), 15_000); return () => clearInterval(timer); }, []);
  void tick.value;
  const now = toWireDate(new Date());
  return (
    <button class="update-now" disabled={down || !canUpdate(update, now)} aria-busy={update.isRunning}
      title={update.workflowID ? `Run \u201C${update.name}\u201D now, as Run now would` : "Start an agent to set every tile again from its source"}
      onClick={() => void store.updateDashboard(host, folder)}>
      {update.isRunning ? "Updating…" : "↻ Update now"}
    </button>
  );
}

/** What is going, why it can't, or how the last one went, with the way to its session. */
function UpdateLine({ host, folder, update }: { host: string; folder: string; update: DashboardUpdate }) {
  const line = updateLine(update, toWireDate(new Date()));
  if (!line) return null;
  const failed = update.lastFailed && !update.isRunning;
  return (
    <p class={`update-line small${failed ? " failure" : " quiet"}`}>{line}
      {update.blocked !== undefined && update.workflowID
        ? <>{" · "}<button class="link" onClick={() => go({ host, project: folder, workflow: update.workflowID })}>Open Workflow</button></>
        : update.agentID && (update.isRunning || update.lastFailed)
          ? <>{" · "}<button class="link" onClick={() => go({ host, project: folder, session: update.agentID })}>Open Session</button></>
          : null}
    </p>
  );
}

/** Move Up, Move Down and Move to <section>: the order without a pointer (#147). */
type MoveItem = { label: string; run: () => void; disabled: boolean };

function moveItems(snapshot: DashboardSnapshot, id: string, includeHidden: boolean,
  groups: { title: string | null; tiles: TileView[] }[],
  arrange: (change: (order: DashboardOrder) => DashboardOrder | null) => void): MoveItem[] {
  const current = groups.find((g) => g.tiles.some((t) => t.id === id))?.title ?? null;
  return [
    { label: "Move Up", disabled: neighbour(groups, id, -1) === null, run: () => arrange(() => stepping(snapshot, id, -1, includeHidden)) },
    { label: "Move Down", disabled: neighbour(groups, id, 1) === null, run: () => arrange(() => stepping(snapshot, id, 1, includeHidden)) },
    ...groups.filter((g) => g.title !== current).map((g) => ({
      label: `Move to ${g.title ?? "No Section"}`, disabled: false, run: () => arrange((o) => moving(o, [id], g.title)),
    })),
  ];
}

function SectionMenu({ down, first, last, onUp, onDown }: {
  down: boolean; first: boolean; last: boolean; onUp: () => void; onDown: () => void;
}) {
  const open = useSignal(false);
  if (first && last) return null;
  return (
    <span class="menu-anchor">
      <button class="icon section-menu" aria-label="Section options" aria-haspopup="true" aria-expanded={open.value}
        onClick={() => (open.value = !open.value)}>···</button>
      {open.value && (
        <div class="popover" role="menu">
          <button role="menuitem" disabled={down || first} onClick={() => { open.value = false; onUp(); }}>Move Section Up</button>
          <button role="menuitem" disabled={down || last} onClick={() => { open.value = false; onDown(); }}>Move Section Down</button>
        </div>
      )}
    </span>
  );
}

function Tile({ store, host, folder, tile, now, down, onDetail, drag, moves }: {
  store: Store; host: string; folder: string; tile: TileView; now: number; down: boolean; onDetail: () => void;
  drag: { start: () => void; end: () => void; over: (e: DragEvent) => void; drop: (e: DragEvent) => void };
  moves: MoveItem[];
}) {
  const menu = useSignal(false);
  const stale = isStale(tile, now);
  const act = (method: "dashboard/hide" | "dashboard/show" | "dashboard/remove") => {
    menu.value = false;
    void store.actOnTile(host, folder, method, tile.id);
  };
  const openKeeper = () => {
    if (tile.keeper.kind === "agent") go({ host, project: folder, session: tile.keeper.id });
    else go({ host, project: folder, workflow: tile.keeper.id });
  };
  const note = keeperNote(tile);
  return (
    <article class={`tile${isWide(tile) ? " wide" : ""}${stale ? " stale" : ""}`} aria-label={tile.tile?.title ?? tile.id}
      draggable={!down} onDragStart={(e) => { drag.start(); e.dataTransfer?.setData("text/plain", tile.id); }}
      onDragEnd={drag.end} onDragOver={drag.over} onDrop={drag.drop}>
      <header>
        <h3>{tile.tile?.title ?? tile.id}{tile.tile?.hidden && <span class="quiet" title="Hidden"> (hidden)</span>}</h3>
        <span class="menu-anchor">
          <button class="icon tile-menu" aria-label="Tile options" aria-haspopup="true" aria-expanded={menu.value}
            onClick={() => (menu.value = !menu.value)}>···</button>
          {menu.value && (
            <div class="popover" role="menu">
              <button role="menuitem" onClick={() => { menu.value = false; onDetail(); }}>Details…</button>
              <button role="menuitem" disabled={!tile.keeper.id} onClick={() => { menu.value = false; openKeeper(); }}>Open Keeper</button>
              <hr />
              {moves.map((item) => (
                <button key={item.label} role="menuitem" disabled={down || item.disabled}
                  onClick={() => { menu.value = false; item.run(); }}>{item.label}</button>
              ))}
              <hr />
              {tile.tile?.hidden
                ? <button role="menuitem" disabled={down} onClick={() => act("dashboard/show")}>Show</button>
                : <button role="menuitem" disabled={down || !tile.tile} onClick={() => act("dashboard/hide")}>Hide</button>}
              <button role="menuitem" disabled={down} onClick={() => act("dashboard/remove")}>Remove</button>
            </div>
          )}
        </span>
      </header>
      <div class="value"><Value store={store} host={host} folder={folder} tile={tile} now={now} /></div>
      <footer class="small quiet">
        <button class="link keeper" disabled={!tile.keeper.id} onClick={openKeeper}
          title={`Open the ${tile.keeper.kind === "workflow" ? "workflow" : "session"} that keeps this tile`}>{tile.keeper.name}</button>
        {" · "}{ageWords(tile, now)}{note && ` · ${note}`}
      </footer>
    </article>
  );
}

function Value({ store, host, folder, tile, now }: { store: Store; host: string; folder: string; tile: TileView; now: number }) {
  const file = tile.tile;
  if (!file) return <p class="failure">⚠︎ {tile.problem ?? "This tile's file can't be read."}</p>;
  switch (file.type) {
    case "number": {
      const number = file.number ?? { value: 0 };
      const delta = change(tile, now);
      const good = delta === null ? null : isGood(delta, number.good);
      const words = changeWords(delta);
      const line = sparkline(tile, 160, 26);
      return (
        <div class="number">
          <p><span class="big">{numberWords(number.value)}</span>
            {number.unit && <span class="unit"> {number.unit}</span>}
            {words && <span class={`delta${isStale(tile, now) ? "" : good === true ? " good" : good === false ? " bad" : ""}`}> {words}</span>}
          </p>
          {line && (
            <svg class="spark" viewBox="0 0 160 26" preserveAspectRatio="none" aria-hidden="true">
              <polyline points={line} fill="none" vector-effect="non-scaling-stroke" />
            </svg>
          )}
        </div>
      );
    }
    case "status": {
      const level = shownLevel(tile, now) ?? "unknown";
      return (
        <p class="tile-status"><span class={`light ${level}`} aria-label={level} /> {file.status?.line}
          {file.status?.since && <span class="small quiet"><br />since {file.status.since}</span>}</p>
      );
    }
    case "table": {
      const table = file.table ?? { columns: [], rows: [] };
      return (
        <table class="tile-table">
          <thead><tr>{table.columns.map((c, i) => <th key={i}>{c}</th>)}</tr></thead>
          <tbody>{table.rows.map((row, r) => <tr key={r}>{row.map((cell, i) => <td key={i}><Cell cell={cell} /></td>)}</tr>)}</tbody>
        </table>
      );
    }
    case "note":
      return <div class="note"><Markdown text={file.note?.markdown ?? ""} /></div>;
    case "link":
      return <LinkValue host={host} folder={folder} link={file.link ?? {}} />;
    case "page":
      return <PageValue store={store} host={host} folder={folder} file={file.page?.file ?? ""} />;
  }
}

function Cell({ cell }: { cell: TileCell }) {
  if (cell.url && isSafeLink(cell.url)) return <a href={cell.url} target="_blank" rel="noopener noreferrer">{cell.text}</a>;
  return <>{cell.text}</>;
}

function LinkValue({ host, folder, link }: { host: string; folder: string; link: TileLink }) {
  if (link.url && isSafeLink(link.url)) {
    return <a href={link.url} target="_blank" rel="noopener noreferrer">{new URL(link.url).host} ↗</a>;
  }
  if (link.session) return <button class="link" onClick={() => go({ host, project: folder, session: link.session })}>A session →</button>;
  if (link.workflow) return <button class="link" onClick={() => go({ host, project: folder, workflow: link.workflow })}>Workflow {link.workflow} →</button>;
  // A document or a page of the project's opens where a pinned one does (#159).
  if (link.file && /\.(md|markdown|mdown|mkd|html?)$/i.test(link.file)) {
    return <button class="link" onClick={() => go({ host, project: folder, page: link.file })}>{link.file} →</button>;
  }
  return <span>{link.file ?? ""}</span>;
}

/**
 * A page tile (#159): the top of the project's document, live, and Open for the whole of it in
 * the chat's place. HTML is its source here, as a pinned one is: the page allows no frames.
 */
function PageValue({ store, host, folder, file }: { store: Store; host: string; folder: string; file: string }) {
  const text = useSignal<string | null>(null);
  const problem = useSignal<string | null>(null);
  const revision = store.pageRevisions.value[`${host}|${folderKey(folder)}`] ?? 0;
  useEffect(() => {
    let gone = false;
    store.readPage(host, folder, file).then((r) => {
      if (gone) return;
      if (r.kind === "text") { text.value = r.text; problem.value = null; }
      else if (r.kind !== "unchanged") problem.value = `${file} can't be shown as a page.`;
    }).catch(() => { if (!gone) problem.value = `${file} isn't in the project folder.`; });
    return () => { gone = true; };
  }, [host, folder, file, revision]);
  const isHTML = /\.html?$/i.test(file);
  return (
    <div class="page-tile">
      {problem.value ? <p class="failure">⚠︎ {problem.value}</p>
        : text.value === null ? <p class="hint">Reading {file}…</p>
        : isHTML ? <pre class="page-tile-body">{text.value}</pre>
        : <div class="page-tile-body note"><Markdown text={text.value} /></div>}
      <p class="small quiet"><span>{file}</span>{" · "}
        <button class="link" onClick={() => go({ host, project: folder, page: file })}>Open</button></p>
    </div>
  );
}

function TileDetail({ tile, now, onClose }: { tile: TileView; now: number; onClose: () => void }) {
  return (
    <div class="tile-detail" role="dialog" aria-label={`${tile.tile?.title ?? tile.id}: details`}>
      <h2>{tile.tile?.title ?? tile.id}</h2>
      <dl>
        <dt>File</dt><dd><code>.agents/dashboard/{tile.id}.json</code></dd>
        {tile.tile?.type === "number" && <><dt>History</dt><dd><code>{historyFile(tile.id)}</code></dd></>}
        <dt>Kept by</dt><dd>{tile.keeper.name} ({tile.keeper.kind}){keeperNote(tile) ? `, ${keeperNote(tile)}` : ""}</dd>
        <dt>Set</dt><dd>{ageWords(tile, now)}</dd>
        {tile.tile?.source && <><dt>Source</dt><dd>{tile.tile.source}</dd></>}
        {tile.changedOutside && <><dt>Changed</dt><dd>outside Agents: the file is not what this host last wrote</dd></>}
        {tile.problem && <><dt>Problem</dt><dd>{tile.problem}</dd></>}
        {tile.keeperChanges.map((c, i) => <><dt key={`k${i}`}>Handed over</dt><dd>{c.from} → {c.to}, {fromWireDate(c.at).toLocaleString()}</dd></>)}
      </dl>
      {tile.recent.length > 0 && (
        <>
          <h3>Last values</h3>
          <ul class="recent">{[...tile.recent].reverse().map((p, i) => (
            <li key={i}><span>{numberWords(p.value)}</span><span class="quiet">{fromWireDate(p.at).toLocaleString()}</span></li>
          ))}</ul>
        </>
      )}
      <button onClick={onClose}>Done</button>
    </div>
  );
}

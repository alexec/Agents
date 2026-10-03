// A project's Dashboard (074), as the window has it: a row at the top of the sessions column, and
// a page in the chat's place with tiles in sections, small ones in a grid and tables and notes
// across. Greyed when stale, with Hide, Show, Remove and the tile's detail behind its ··· menu.
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { Store } from "../model/store";
import { folderKey } from "../model/groups";
import {
  ageWords, agoWords, change, changeWords, filesSentence, historyFile, isGood, isStale, isWide, keeperNote, numberWords, rowDetail,
  sections, shownLevel, sparkline,
} from "../model/dashboard";
import { isSafeLink, Markdown } from "../render/markdown";
import type { TileCell, TileLink, TileView } from "../protocol/generated";
import { go } from "../route";
import { fromWireDate } from "../protocol/dates";

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
  return (
    <section class="chat dashboard-page" aria-label="Dashboard">
      <header class="column-head">{back}<h1>Dashboard</h1>
        <label class="show-hidden small quiet">
          <input type="checkbox" checked={showsHidden.value}
            onChange={(e) => (showsHidden.value = (e.currentTarget as HTMLInputElement).checked)} />
          Show Hidden Tiles{hiddenCount > 0 ? ` (${hiddenCount})` : ""}
        </label>
      </header>
      <div class="scroll">
        <div class="dashboard-body">
          <p class="quiet">{projectName}{Number.isFinite(newest) && snapshot
            ? ` · updated ${agoWords(snapshot.now - newest)}` : " · kept by its agents"}</p>
          {!snapshot && <p class="hint">Loading…</p>}
          {snapshot && groups.length === 0 && (
            <p class="hint">{hiddenCount > 0 ? "Every tile is hidden. Show Hidden Tiles brings them back."
              : "No tiles yet. Agents keep tiles here with set_tile: a number with its trend, a status, a table, a note or a link."}</p>
          )}
          {groups.map((section) => (
            <div class="tile-section" key={section.title ?? ""}>
              {section.title && <h2 class="section-head">{section.title}</h2>}
              <div class="tile-grid">
                {section.tiles.map((tile) => (
                  <Tile key={tile.id} store={store} host={host} folder={folder} tile={tile} now={snapshot!.now} down={down}
                    onDetail={() => (detail.value = tile.id)} />
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

function Tile({ store, host, folder, tile, now, down, onDetail }: {
  store: Store; host: string; folder: string; tile: TileView; now: number; down: boolean; onDetail: () => void;
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
    <article class={`tile${isWide(tile) ? " wide" : ""}${stale ? " stale" : ""}`} aria-label={tile.tile?.title ?? tile.id}>
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

function Value({ host, folder, tile, now }: { store: Store; host: string; folder: string; tile: TileView; now: number }) {
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
        <p class="status"><span class={`light ${level}`} aria-label={level} /> {file.status?.line}
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
  return <span>{link.file ?? ""}</span>;
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

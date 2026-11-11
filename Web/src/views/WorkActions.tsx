// The actions on an issue's or a pull request's Work page (#3130): the comment box with Close or Reopen, a tracker's
// status menu (#3260) and the labels picker on any item; on a pull request the merge box (Merge, Approve, Rerun
// failed and the failed checks' logs), Files changed and the Checks page (#4408). Each goes to the machine that read the
// item (forge/*), as the person: their own click, so no approval card. `wrote` reads the page again.
import { signal, useSignal } from "@preact/signals";
import { useEffect, useMemo, useRef } from "preact/hooks";
import type { ForgeCheck, ForgeDone, ForgeItemDetail, ForgeLabel, ForgeMergeMethod, LineageNode } from "../protocol/generated";
import type { Store } from "../model/store";
import { describe } from "../model/errors";
import { doneWords, forgeName, mergeButton, shortRef } from "../model/work";
import {
  checkSign, checksInOrder, checksPageWords, filesChangedWords, mergeMain, noWriter, offers, readyOnForge, resolveOnForge,
  type MergeBox, type MergeRow,
} from "../model/workPull";
import type { Diff } from "./chat/appViewBridge";
import { ViewDiff } from "./chat/ViewDiff";
import { openContextMenu, type MenuItem } from "./ContextMenu";
import { Modal } from "./Modal";
import { StateIcon } from "./WorkParts";

const openLink = (url: string) => { window.open(url, "_blank", "noopener,noreferrer"); };

/** The end of a check's log, in a sheet (forge/log). */
export function WorkLogSheet({ log, close }: { log: { title: string; text: string } | null; close: () => void }) {
  if (!log) return null;
  return (
    <Modal label={log.title} close={close}>
      <div class="work-log">
        <header><h2>{log.title}</h2><span class="spacer" />
          <button type="button" class="prominent" onClick={close}>Done</button></header>
        <pre>{log.text}</pre>
      </div>
    </Modal>
  );
}

/** A merge box row's glyph, in its sign's colour: a tick, a cross, an eye (a review to give), a dot (running), a
 * warning (conflicts), a clock (auto-merge), a page (a draft). */
function MergeGlyph({ row }: { row: MergeRow }) {
  const glyph = row.kind === "draft" ? "▤" : row.kind === "autoMerge" ? "◷" : row.kind === "review" && row.sign === "wait" ? "◉"
    : row.kind === "conflicts" && row.sign === "fail" ? "⚠" : row.sign === "fail" ? "✕" : row.sign === "wait" ? "●" : "✓";
  return <span class={`work-merge-glyph ${row.sign}`} aria-hidden="true">{glyph}</span>;
}

const checkGlyph = (state: string) => state === "passing" ? "✓" : state === "failing" ? "✕" : state === "running" ? "●" : "⊘";
const checkWord: Record<string, string> = { passing: "passed", failing: "failed", running: "running", skipped: "skipped" };

/** A check's glyph in its sign's colour, its state said to a screen reader. */
function CheckGlyph({ state }: { state: string }) {
  return <span class={`work-merge-glyph ${checkSign(state)}`} role="img" aria-label={checkWord[state] ?? state}>{checkGlyph(state)}</span>;
}

/** A pull request's merge box (pull-request.md note 10), as the window's WorkMergeBox (#4406): a bordered box at the end
 * of the timeline (at the top of a page under 700 px, `top`) with a row for the review, the checks and conflicts, each
 * with a glyph in its state's colour, then Merge ▾, Approve and Rerun failed. The checks list opens with Show all, and
 * is open from the start when a check failed; a failed check has Log. On the top box the checks row opens the Checks
 * page (`checksPage`) in place of the list. `writes`: a machine of the person's writes to the forge; else the rows and
 * why no buttons. */
export function WorkMergeBox({ store, host, detail, box, writes, top = false, checksPage, wrote }: {
  store: Store; host: string; detail: ForgeItemDetail; box: MergeBox; writes: boolean; top?: boolean;
  checksPage?: (() => void) | undefined; wrote: () => void;
}) {
  const busy = useSignal(false);
  const said = useSignal<{ words: string; failed: boolean } | null>(null);
  const log = useSignal<{ title: string; text: string } | null>(null);
  const shows = useSignal<boolean | null>(null);
  const item = detail.item;
  const node = item.node;
  const checks = checksInOrder(detail.checks ?? []);
  const open = shows.value ?? box.checksOpen;
  const reads = offers(detail, "log");

  const act = async (method: "forge/merge" | "forge/approve" | "forge/rerun", params: unknown) => {
    busy.value = true;
    try {
      const done = await store.link.call(method, params as never, host) as ForgeDone;
      said.value = { words: doneWords(method, done), failed: false };
      wrote();
    } catch (e) {
      said.value = { words: describe(e), failed: true };
    } finally {
      busy.value = false;
    }
  };
  const readLog = async (check: string) => {
    busy.value = true;
    try {
      const r = await store.link.call("forge/log", { node, check }, host);
      log.value = { title: check, text: r.text };
    } catch (e) {
      said.value = { words: describe(e), failed: true };
    } finally {
      busy.value = false;
    }
  };

  const methods = detail.mergeMethods ?? [];
  const merge = (method: ForgeMergeMethod | undefined, auto: boolean) => detail.head && void act("forge/merge", {
    node, sha: detail.head, ...method ? { method } : {}, ...auto ? { auto: true } : {},
  });
  // The menu: the other methods, then Merge when checks pass (auto-merge, when the forge offers it).
  const menu: MenuItem[] = [
    ...methods.slice(1).map((m): MenuItem => ({ label: mergeButton(m, box.waits), run: () => merge(m, box.waits) })),
    ...box.waits || !offers(detail, "autoMerge") ? [] : [{ label: "Merge when checks pass", run: () => merge(methods[0], true) }],
  ];

  return (
    <div class={`work-merge${top ? " top" : ""}`}>
      {!top && (
        <span class={`work-merge-mark${item.draft ? " draft" : ""}`} aria-hidden="true"><StateIcon kind="pr" state="open" draft={item.draft} size={14} /></span>
      )}
      <section class={`work-merge-box ${box.border}`} aria-label="Merge">
        {box.rows.map((row) => (
          <div key={row.kind} class="work-merge-row-wrap">
            {row.kind === "checks" && top && checks.length > 0 && checksPage ? (
              <button type="button" class="work-merge-row link-row" onClick={checksPage} aria-label={`${row.title}: the checks`}>
                <MergeGlyph row={row} />
                <span class="words"><span class="strong">{row.title}</span>{row.line && <span class="quiet small">{row.line}</span>}</span>
                <span class="quiet small">{checks.length} <span aria-hidden="true">›</span></span>
              </button>
            ) : (
              <div class="work-merge-row">
                <MergeGlyph row={row} />
                <span class="words"><span class="strong">{row.title}</span>{row.line && <span class="quiet small">{row.line}</span>}</span>
                {row.kind === "checks" && checks.length > 0 && (
                  <button type="button" class="link small" aria-expanded={open} onClick={() => { shows.value = !open; }}>{open ? "Hide" : "Show all"}</button>
                )}
              </div>
            )}
            {row.kind === "checks" && open && !top && checks.length > 0 && (
              <ul class="work-checks">
                {checks.map((c, i) => (
                  <li key={`${c.name}-${i}`}>
                    <CheckGlyph state={c.state} />
                    <span class="name" title={c.name}>{c.name}</span>
                    {c.state === "failing" && writes && reads
                      ? <button type="button" class="link" disabled={busy.value} title="The end of this check's log" onClick={() => void readLog(c.name)}>Log</button>
                      : c.url && <a href={c.url} target="_blank" rel="noopener noreferrer">Details</a>}
                  </li>
                ))}
              </ul>
            )}
          </div>
        ))}
        <div class="work-merge-buttons">
          {!writes ? <p class="quiet small">{noWriter(node.ref)}</p>
            : item.draft ? <p class="quiet small">{readyOnForge(node.ref)}</p>
            : (
              <div class="work-actions-bar">
                {box.merges && detail.head && (
                  <span class={`split-button work-merge-button${box.waits ? " waits" : ""}`}>
                    <button type="button" class="prominent" disabled={busy.value} onClick={() => merge(methods[0], box.waits)}>{mergeMain(methods, box.waits)}</button>
                    <button type="button" class="prominent" disabled={busy.value || menu.length === 0} aria-label="More ways to merge"
                      onClick={(e) => openContextMenu(e, menu)}>▾</button>
                  </span>
                )}
                {box.resolve && item.url && <button type="button" onClick={() => openLink(`${item.url}/conflicts`)}>{resolveOnForge(node.ref)}</button>}
                {box.approves && detail.head && (
                  <button type="button" class="work-approve" disabled={busy.value} onClick={() => void act("forge/approve", { node, sha: detail.head })}>
                    <span aria-hidden="true">✓</span>Approve</button>
                )}
                {box.reruns && (
                  <button type="button" class="work-rerun" disabled={busy.value} onClick={() => void act("forge/rerun", { node })}>
                    <span aria-hidden="true">↻</span>Rerun failed</button>
                )}
                {busy.value && <span class="work-spinner" aria-label="Working" />}
              </div>
            )}
          {said.value && <p class={said.value.failed ? "hint failure small" : "quiet small"} role="status">{said.value.words}</p>}
        </div>
      </section>
      <WorkLogSheet log={log.value} close={() => { log.value = null; }} />
    </div>
  );
}

/** Files changed 6 (pull-request.md note 5), as the window's WorkFilesChanged: a bordered button at the title's
 * trailing end, or (`row`, a page under 700 px) a full-width row, Files changed · 6 ›. It opens the diff (forge/diff)
 * as a sheet. */
export function WorkFilesChanged({ store, host, detail, row = false }: { store: Store; host: string; detail: ForgeItemDetail; row?: boolean }) {
  const loading = useSignal(false);
  const problem = useSignal<string | null>(null);
  const diff = useMemo(() => signal<Diff | null>(null), []);
  const node = detail.item.node;
  if (!offers(detail, "diff")) return null;
  const show = async () => {
    loading.value = true;
    problem.value = null;
    try {
      const d = await store.link.call("forge/diff", { node }, host);
      diff.value = { title: `${shortRef(node.ref)} ${detail.item.title}`, url: d.url, files: d.files, cut: d.cut, site: forgeName(node.ref) };
    } catch (e) {
      problem.value = describe(e);
    } finally {
      loading.value = false;
    }
  };
  const n = detail.filesChanged;
  return (
    <span class={row ? "work-files-row" : "work-files"}>
      <button type="button" disabled={loading.value} onClick={() => void show()} title="The pull request's diff">
        <svg class="work-files-glyph" width="14" height="14" viewBox="0 0 16 16" aria-hidden="true">
          <path d="M5.5 1.75h5.25l3 3v7.5a1 1 0 0 1-1 1H5.5a1 1 0 0 1-1-1v-9.5a1 1 0 0 1 1-1ZM2.25 4.5v9.25a1 1 0 0 0 1 1h7" /></svg>
        {row ? <><span class="words">Files changed</span>{loading.value && <span class="work-spinner" aria-label="Loading" />}
          {n !== undefined && <span class="quiet">{n}</span>}<span class="quiet" aria-hidden="true">›</span></>
          : <>{filesChangedWords(n)}{loading.value && <span class="work-spinner" aria-label="Loading" />}</>}
      </button>
      {problem.value && <span class="hint failure small">{problem.value}</span>}
      <ViewDiff layer={{ diff }} openLink={openLink} />
    </span>
  );
}

/** The Checks page of a page under 700 px (pull-request.md note 17), pushed from the merge box's checks row: ‹ #4402,
 * "1 failed, 12 passed, 1 running", Rerun failed full width, then a row per check with a chevron. A check opens the end
 * of its log in a sheet; one with no log, or with no machine that reads it, its page on the forge. */
export function WorkChecksPage({ store, host, detail, writes, back, wrote }: {
  store: Store; host: string; detail: ForgeItemDetail; writes: boolean; back: () => void; wrote: () => void;
}) {
  const busy = useSignal(false);
  const said = useSignal<{ words: string; failed: boolean } | null>(null);
  const log = useSignal<{ title: string; text: string } | null>(null);
  const node = detail.item.node;
  const checks = checksInOrder(detail.checks ?? []);
  const failed = checks.some((c) => c.state === "failing");
  const reads = writes && offers(detail, "log");
  const run = async <T,>(get: () => Promise<T>, then: (t: T) => void) => {
    busy.value = true;
    try {
      then(await get());
    } catch (e) {
      said.value = { words: describe(e), failed: true };
    } finally {
      busy.value = false;
    }
  };
  const open = (c: ForgeCheck) => {
    if (reads && c.state === "failing") void run(() => store.link.call("forge/log", { node, check: c.name }, host), (r) => { log.value = { title: c.name, text: r.text }; });
    else if (c.url) openLink(c.url);
  };
  useEffect(() => {
    const escape = (e: KeyboardEvent) => { if (e.key === "Escape" && !log.value) back(); };
    addEventListener("keydown", escape);
    return () => removeEventListener("keydown", escape);
  }, []);
  return (
    <section class="work-checks-page" aria-label="Checks">
      <div class="work-page-bar">
        <nav class="work-place" aria-label="Place">
          <button type="button" class="link" onClick={back}><span aria-hidden="true">‹ </span>{shortRef(node.ref)}</button>
        </nav>
      </div>
      <h2>Checks</h2>
      <p class="quiet small">{checksPageWords(checks)}</p>
      {failed && writes && offers(detail, "rerun") && (
        <button type="button" class="work-rerun wide" disabled={busy.value}
          onClick={() => void run(() => store.link.call("forge/rerun", { node }, host) as Promise<ForgeDone>, (done) => {
            said.value = { words: doneWords("forge/rerun", done), failed: false };
            wrote();
          })}><span aria-hidden="true">↻</span>Rerun failed</button>
      )}
      {said.value && <p class={said.value.failed ? "hint failure small" : "quiet small"} role="status">{said.value.words}</p>}
      <ul class="work-checks-list">
        {checks.map((c, i) => {
          const opens = (reads && c.state === "failing") || !!c.url;
          return (
            <li key={`${c.name}-${i}`}>
              <button type="button" disabled={!opens || busy.value} onClick={() => open(c)}
                title={reads && c.state === "failing" ? "The end of this check's log" : c.url ? `Its page on ${forgeName(node.ref)}` : undefined}>
                <CheckGlyph state={c.state} /><span class="name">{c.name}</span>
                {opens && <span class="quiet" aria-hidden="true">›</span>}
              </button>
            </li>
          );
        })}
      </ul>
      <WorkLogSheet log={log.value} close={() => { log.value = null; }} />
    </section>
  );
}

/** The comment box at the end of the timeline (#3130; #4402 note 11): the person's glyph, a Markdown field, then Close
 * issue (Close with comment, with text in the field) or Reopen issue beside Comment (⌘↩). `closes` is the item's state
 * when its close is here (an issue with no tracker's status, an open or closed pull request, #4408).
 * What a write did, or why not, is the line under the buttons. */
export function WorkCommentBox({ store, host, node, closes, noun = "issue", said, wrote }: {
  store: Store; host: string; node: LineageNode; closes?: string | undefined; noun?: string;
  said?: { words: string; failed: boolean } | null | undefined; wrote: (words: string, failed: boolean) => void;
}) {
  const text = useSignal("");
  const sending = useSignal(false);
  const empty = !text.value.trim();
  const comment = async (): Promise<boolean> => {
    try {
      await store.link.call("forge/comment", { node, body: text.value }, host);
      text.value = "";
      wrote(doneWords("forge/comment", {} as ForgeDone), false);
      return true;
    } catch (e) {
      wrote(describe(e), true);
      return false;
    }
  };
  const send = async (close?: "close" | "reopen") => {
    if (sending.value) return;
    sending.value = true;
    try {
      // The comment first, when there is one, then the close or the reopen.
      if (!empty && !await comment()) return;
      if (!close) return;
      const reopen = close === "reopen";
      const done = await store.link.call("forge/close", { node, ...reopen ? { reopen: true } : {} }, host);
      wrote(doneWords("forge/close", done, reopen), false);
    } catch (e) {
      wrote(describe(e), true);
    } finally {
      sending.value = false;
    }
  };
  const closeWords = closes === "open" ? (empty ? `Close ${noun}` : "Close with comment") : (empty ? `Reopen ${noun}` : "Reopen with comment");
  return (
    <form class="work-comment-box" onSubmit={(e) => { e.preventDefault(); if (!empty) void send(); }}>
      {/* The person's avatar comes with the forge's login for them (#4363); a person's glyph till then. */}
      <span class="work-comment-me" aria-hidden="true">
        <svg width="28" height="28" viewBox="0 0 28 28"><circle cx="14" cy="14" r="14" /><circle cx="14" cy="11" r="4.5" class="cut" />
          <path d="M6 23.5a9 9 0 0 1 16 0" class="cut" /></svg>
      </span>
      <div class="work-comment-box-main">
        <textarea aria-label="New comment" rows={4} value={text.value} placeholder="Comment, in Markdown"
          onInput={(e) => { text.value = e.currentTarget.value; }}
          onKeyDown={(e) => { if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); if (!empty) void send(); } }} />
        <div class="work-actions-bar">
          {sending.value && <span class="work-spinner" aria-label="Sending" />}
          <span class="spacer" />
          {(closes === "open" || closes === "closed") && (
            <button type="button" disabled={sending.value} onClick={() => void send(closes === "open" ? "close" : "reopen")}
              title={closes === "open" ? (noun === "issue" ? "Close it as completed" : "Close it without merging") : undefined}>
              <span aria-hidden="true" class={`work-close-mark ${closes}${noun === "issue" ? "" : " pull"}`}>{closes === "open" ? (noun === "issue" ? "✓" : "✕") : "↺"}</span>{closeWords}</button>
          )}
          <button type="submit" class="prominent" disabled={sending.value || empty} title="Comment (⌘↩)">Comment</button>
        </div>
        {said && <p class={said.failed ? "hint failure small" : "quiet small"} role="status">{said.words}</p>}
      </div>
    </form>
  );
}

/** A tracker's status in the state pill's place (#3260; #4402 note 6): the status in its state's colour, its menu the
 * moves its workflow allows now. */
export function WorkStatusMenu({ state, status, transitions, busy, move }: {
  state: string; status: string | undefined; transitions: readonly { id: string; name: string }[]; busy: boolean; move: (id: string) => void;
}) {
  const menu = (event: MouseEvent) => openContextMenu(event, transitions.map((t): MenuItem => ({ label: t.name, run: () => move(t.id) })));
  return (
    <button type="button" class={`work-state work-status-menu ${state}`} disabled={busy || transitions.length === 0} onClick={menu}
      title={transitions.length === 0 ? "No moves" : "Move it by its workflow"}>{status ?? "Status"} <span aria-hidden="true">▾</span></button>
  );
}

/** The labels picker (#4402 note 12), from the gear on the side panel's Labels: a popover with a filter field and a
 * tick on each label the item has (forge/labels); a click adds the label or takes it off. */
export function WorkLabelsPicker({ store, host, node, has, close, pick }: {
  store: Store; host: string; node: LineageNode; has: readonly ForgeLabel[]; close: () => void; pick: (name: string, add: boolean) => void;
}) {
  const choices = useSignal<ForgeLabel[] | null>(null);
  const failed = useSignal<string | null>(null);
  const text = useSignal("");
  useEffect(() => {
    let current = true;
    store.link.call("forge/labels", { node }, host).then((r) => { if (current) choices.value = r.labels; }, (e) => {
      if (current) { choices.value = []; failed.value = describe(e); }
    });
    return () => { current = false; };
  }, [node.ref, host]);
  const at = useRef<HTMLDivElement>(null);
  // Escape, or a click outside it and its gear, closes it.
  useEffect(() => {
    const escape = (e: KeyboardEvent) => { if (e.key === "Escape") { e.stopPropagation(); close(); } };
    const away = (e: Event) => {
      const t = e.target as Element | null;
      if (!at.current?.contains(t) && !t?.closest?.(".work-gear")) close();
    };
    addEventListener("keydown", escape);
    addEventListener("pointerdown", away);
    return () => { removeEventListener("keydown", escape); removeEventListener("pointerdown", away); };
  }, []);
  const words = text.value.trim().toLowerCase();
  const shown = (choices.value ?? []).filter((l) => !words || l.name.toLowerCase().includes(words));
  return (
    <div class="popover work-labels-picker" role="dialog" aria-label="Labels" ref={at}>
      <input type="search" placeholder="Filter labels" aria-label="Filter labels" value={text.value} autoFocus
        onInput={(e) => { text.value = e.currentTarget.value; }} />
      <div class="work-labels-choices" role="group" aria-label="Labels">
        {choices.value === null ? <span class="quiet small">Loading…</span>
          : failed.value ? <span class="hint failure small">{failed.value}</span>
          : shown.length === 0 ? <span class="quiet small">{choices.value.length === 0 ? "No labels" : "No label matches"}</span>
          : shown.map((l) => {
            const on = has.some((x) => x.name === l.name);
            return (
              <button key={l.name} type="button" role="menuitemcheckbox" aria-checked={on} title={on ? "Take it off" : "Add it"}
                onClick={() => pick(l.name, !on)}>
                <span class="tick" aria-hidden="true">{on ? "✓" : ""}</span>
                <span class="work-label-dot" style={l.color ? { background: `#${l.color.replace(/^#/, "")}` } : undefined} aria-hidden="true" />
                <span class="name">{l.name}</span>
              </button>
            );
          })}
      </div>
    </div>
  );
}

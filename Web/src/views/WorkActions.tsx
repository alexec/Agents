// The actions on an issue's or a pull request's Work page (#3130), as the window's WorkItemActions:
// Start Agent, labels and Close or Reopen on an issue (a Jira issue's status menu in their place,
// #3260); Merge, Approve, Rerun, the failed checks' logs and Show Diff on a pull request; a comment
// on either. Each goes to the machine that read the item (forge/*), as the person: their own click,
// so no approval card. `wrote` reads the page again.
import { signal, useSignal } from "@preact/signals";
import { useEffect, useMemo } from "preact/hooks";
import type { ForgeDone, ForgeItemDetail, ForgeLabel, ForgeMergeMethod, LineageNode } from "../protocol/generated";
import type { Store } from "../model/store";
import { describe } from "../model/errors";
import { closeTitle, doneWords, failedChecks, forgeName, mergeButton, mergeWaits, shortRef, takesLabels } from "../model/work";
import type { Diff } from "./chat/appViewBridge";
import { ViewDiff } from "./chat/ViewDiff";
import { openContextMenu, type MenuItem } from "./ContextMenu";
import { Modal } from "./Modal";
import { offerStart } from "./NewAgent";

type Write = "forge/comment" | "forge/label" | "forge/close" | "forge/merge" | "forge/approve" | "forge/rerun";

const openLink = (url: string) => { window.open(url, "_blank", "noopener,noreferrer"); };

export function WorkActions({ store, host, detail, wrote }: {
  store: Store; host: string; detail: ForgeItemDetail; wrote: () => void;
}) {
  const busy = useSignal(false);
  const said = useSignal<{ words: string; failed: boolean } | null>(null);
  const labelChoices = useSignal<ForgeLabel[] | null>(null);
  const log = useSignal<{ title: string; text: string } | null>(null);
  const diff = useMemo(() => signal<Diff | null>(null), []);
  const item = detail.item;
  const node = item.node;
  const isPR = node.kind === "pr";
  const failed = isPR ? failedChecks(detail) : [];

  useEffect(() => {
    let current = true;
    labelChoices.value = null;
    if (!takesLabels(node)) return;
    store.link.call("forge/labels", { node }, host).then((r) => { if (current) labelChoices.value = r.labels; }, () => {
      if (current) labelChoices.value = [];
    });
    return () => { current = false; };
  }, [node.ref, host]);

  const act = async (method: Write, params: unknown) => {
    busy.value = true;
    try {
      const done = await store.link.call(method, params as never, host) as ForgeDone;
      const close = method === "forge/close" ? params as { reopen?: boolean; transition?: string } : {};
      said.value = { words: doneWords(method, done, close.reopen === true, close.transition !== undefined), failed: false };
      wrote();
    } catch (e) {
      said.value = { words: describe(e), failed: true };
    } finally {
      busy.value = false;
    }
  };
  const read = async <T,>(get: () => Promise<T>, then: (t: T) => void) => {
    busy.value = true;
    try {
      then(await get());
    } catch (e) {
      said.value = { words: describe(e), failed: true };
    } finally {
      busy.value = false;
    }
  };

  const startAgent = () => {
    const start = detail.start;
    if (!start) return;
    if (!item.folder) { said.value = { words: "No folder on this machine is on this issue's repo.", failed: true }; return; }
    const why = offerStart(store, host, item.folder, { prompt: start.prompt, labels: start.labels, worktree: start.worktree });
    if (why) said.value = { words: why, failed: true };
  };

  const methods = detail.mergeMethods ?? [];
  const waits = mergeWaits(detail);
  const merge = (method: ForgeMergeMethod | undefined, auto: boolean) => detail.head && void act("forge/merge", {
    node, sha: detail.head, ...method ? { method } : {}, ...auto ? { auto: true } : {},
  });
  const mergeMenu = (event: MouseEvent) => openContextMenu(event, [
    ...methods.slice(1).map((m): MenuItem => ({ label: mergeButton(m, waits), run: () => merge(m, waits) })),
    ...waits ? [] : [{ label: "Merge when checks pass", run: () => merge(methods[0], true) }],
  ]);
  // A Jira issue's status (#3260): the moves its workflow allows now, as Jira shows them.
  const transitions = detail.transitions;
  const statusMenu = (event: MouseEvent) => openContextMenu(event, (transitions ?? []).map((t): MenuItem => ({
    label: t.name, run: () => void act("forge/close", { node, transition: t.id }),
  })));
  const labelMenu = (event: MouseEvent) => openContextMenu(event, (labelChoices.value ?? []).map((l): MenuItem => {
    const on = item.labels.some((x) => x.name === l.name);
    return { label: `${on ? "✓ " : ""}${l.name}`, help: on ? "Take it off" : "Add it",
      run: () => void act("forge/label", { node, ...on ? { remove: [l.name] } : { add: [l.name] } }) };
  }));

  return (
    <div class="work-actions">
      <div class="work-actions-bar">
        {!isPR && detail.start && <button type="button" class="prominent" disabled={busy.value} onClick={startAgent}
          title="The new-agent form in this issue's folder, filled in for it">Start Agent</button>}
        {isPR && item.state === "open" && detail.head && (
          <span class="split-button">
            <button type="button" class="prominent" disabled={busy.value} onClick={() => merge(methods[0], waits)}>{mergeButton(methods[0], waits)}</button>
            <button type="button" class="prominent" disabled={busy.value} aria-label="More ways to merge" onClick={mergeMenu}>▾</button>
          </span>
        )}
        {isPR && item.state === "open" && detail.head && (
          <button type="button" disabled={busy.value} onClick={() => void act("forge/approve", { node, sha: detail.head })}>Approve</button>
        )}
        {item.state === "open" && failed.length > 0 && <button type="button" disabled={busy.value} onClick={() => void act("forge/rerun", { node })}>Rerun failed</button>}
        {isPR && <button type="button" disabled={busy.value} onClick={() => void read(() => store.link.call("forge/diff", { node }, host), (d) => {
          diff.value = { title: `${shortRef(node.ref)} ${item.title}`, url: d.url, files: d.files, cut: d.cut, site: forgeName(node.ref) };
        })}>Show Diff</button>}
        {transitions && <button type="button" disabled={busy.value || transitions.length === 0} onClick={statusMenu}
          title={transitions.length === 0 ? "No moves" : "Move it by its workflow"}>{item.status ?? "Status"} ▾</button>}
        {!transitions && (item.state === "open" || item.state === "closed") && (
          <button type="button" disabled={busy.value}
            onClick={() => void act("forge/close", { node, ...item.state === "open" ? {} : { reopen: true } })}>{closeTitle(item.state)}</button>
        )}
        {takesLabels(node) && <button type="button" disabled={busy.value || !labelChoices.value?.length} onClick={labelMenu}
          title={labelChoices.value === null ? "Loading…" : labelChoices.value.length === 0 ? "No labels" : undefined}>Labels ▾</button>}
        {busy.value && <span class="quiet small">Working…</span>}
      </div>
      {failed.length > 0 && (
        <p class="small"><span class="quiet">Failed:</span> {failed.map((c) => (
          <button key={c.name} type="button" class="link" disabled={busy.value} title="The end of this check's log"
            onClick={() => void read(() => store.link.call("forge/log", { node, check: c.name }, host), (r) => { log.value = { title: c.name, text: r.text }; })}>
            {c.name} log</button>
        ))}</p>
      )}
      {said.value && <p class={said.value.failed ? "hint failure small" : "quiet small"} role="status">{said.value.words}</p>}
      {log.value && (
        <Modal label={log.value.title} close={() => { log.value = null; }}>
          <div class="work-log">
            <header><h2>{log.value.title}</h2><span class="spacer" />
              <button type="button" class="prominent" onClick={() => { log.value = null; }}>Done</button></header>
            <pre>{log.value.text}</pre>
          </div>
        </Modal>
      )}
      <ViewDiff layer={{ diff }} openLink={openLink} />
    </div>
  );
}

/** The comment box at the end of the timeline (#3130; #4402 note 11): the person's glyph, a Markdown field, then Close
 * issue (Close with comment, with text in the field) or Reopen issue beside Comment (⌘↩). `closes` is the item's state
 * when its close is here (an issue with no tracker's status); a pull request's is in its actions row (#4408 moves it).
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
              <span aria-hidden="true" class={`work-close-mark ${closes}`}>{closes === "open" ? "✓" : "↺"}</span>{closeWords}</button>
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
  useEffect(() => {
    const escape = (e: KeyboardEvent) => { if (e.key === "Escape") { e.stopPropagation(); close(); } };
    addEventListener("keydown", escape);
    return () => removeEventListener("keydown", escape);
  }, []);
  const words = text.value.trim().toLowerCase();
  const shown = (choices.value ?? []).filter((l) => !words || l.name.toLowerCase().includes(words));
  return (
    <div class="popover work-labels-picker" role="dialog" aria-label="Labels">
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

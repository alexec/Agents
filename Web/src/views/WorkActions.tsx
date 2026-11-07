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
import { closeTitle, doneWords, failedChecks, forgeName, mergeButton, mergeWaits, shortRef } from "../model/work";
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
          diff.value = { title: `${shortRef(node.ref)} ${item.title}`, url: d.url, files: d.files, cut: d.cut };
        })}>Show Diff</button>}
        {transitions && <button type="button" disabled={busy.value || transitions.length === 0} onClick={statusMenu}
          title={transitions.length === 0 ? "No moves" : "Move it by its workflow"}>{item.status ?? "Status"} ▾</button>}
        {!transitions && (item.state === "open" || item.state === "closed") && (
          <button type="button" disabled={busy.value}
            onClick={() => void act("forge/close", { node, ...item.state === "open" ? {} : { reopen: true } })}>{closeTitle(item.state)}</button>
        )}
        <button type="button" disabled={busy.value || !labelChoices.value?.length} onClick={labelMenu}
          title={labelChoices.value === null ? "Loading…" : labelChoices.value.length === 0 ? "No labels" : undefined}>Labels ▾</button>
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
      <ViewDiff layer={{ diff }} openLink={openLink} site={forgeName(node.ref)} />
    </div>
  );
}

/** A comment box under an item's comments (#3130): Markdown, sent as the person. */
export function WorkCommentBox({ store, host, node, wrote }: { store: Store; host: string; node: LineageNode; wrote: () => void }) {
  const text = useSignal("");
  const sending = useSignal(false);
  const failure = useSignal<string | null>(null);
  const send = async () => {
    sending.value = true;
    failure.value = null;
    try {
      await store.link.call("forge/comment", { node, body: text.value }, host);
      text.value = "";
      wrote();
    } catch (e) {
      failure.value = describe(e);
    } finally {
      sending.value = false;
    }
  };
  return (
    <form class="work-comment-box" onSubmit={(e) => { e.preventDefault(); void send(); }}>
      <textarea aria-label="New comment" rows={3} value={text.value} placeholder="Comment, in Markdown"
        onInput={(e) => { text.value = e.currentTarget.value; }}
        onKeyDown={(e) => { if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); void send(); } }} />
      <div class="work-actions-bar">
        {failure.value && <span class="hint failure small">{failure.value}</span>}
        <span class="spacer" />
        <button type="submit" disabled={sending.value || !text.value.trim()}>{sending.value ? "Sending…" : "Comment"}</button>
      </div>
    </form>
  );
}

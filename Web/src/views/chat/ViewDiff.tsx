// A view's agents/open-diff (#1341): a pull request's files over the chat or the pin, drawn with
// the Review page's diff (FileDiff, #1472), not in the view. Each file's hunks under its path and
// counts; long unchanged runs folded, a break between hunks. Unified, or Side by Side on a wide
// page. Done or Escape closes it. The Mac's and the Remote's is Shared/UI/AppView/AppViewDiffPage.swift.
import { useSignal } from "@preact/signals";
import { useEffect, useMemo, useRef } from "preact/hooks";
import { hunkRows } from "../../model/fileDiff";
import { FileDiff, type DiffLayout } from "../FileDiff";
import type { ViewLayer } from "./viewLayer";

const layoutKey = "reviewDiffLayout";

export function ViewDiff({ layer, openLink }: { layer: ViewLayer; openLink: (url: string) => void }) {
  const diff = layer.diff.value;
  const layout = useSignal<DiffLayout>(globalThis.localStorage?.getItem(layoutKey) === "sideBySide" ? "sideBySide" : "unified");
  const wide = useSignal(typeof innerWidth === "number" && innerWidth >= 820);
  const body = useRef<HTMLDivElement>(null);
  const rows = useMemo(() => (diff?.files ?? []).map((f) => hunkRows(f.hunks)), [diff]);

  useEffect(() => {
    if (!diff) return;
    const close = (e: KeyboardEvent) => { if (e.key === "Escape") { e.preventDefault(); layer.diff.value = null; } };
    const size = () => { wide.value = innerWidth >= 820; };
    size();
    addEventListener("keydown", close);
    addEventListener("resize", size);
    if (diff.path) body.current?.querySelector(`[data-path="${CSS.escape(diff.path)}"]`)?.scrollIntoView({ block: "start" });
    return () => { removeEventListener("keydown", close); removeEventListener("resize", size); };
  }, [diff]);

  if (!diff) return null;
  const added = diff.files.reduce((n, f) => n + f.additions, 0), removed = diff.files.reduce((n, f) => n + f.deletions, 0);
  const choose = (next: DiffLayout) => { layout.value = next; globalThis.localStorage?.setItem(layoutKey, next); };
  return (
    <div class="view-diff" role="dialog" aria-modal="true" aria-label={diff.title}>
      <header class="column-head">
        <h1>{diff.title}</h1>
        <span class="spacer" />
        {wide.value && (
          <span class="tabs" role="tablist" aria-label="Show">
            <button type="button" role="tab" class={layout.value === "unified" ? "on" : ""} aria-selected={layout.value === "unified"} onClick={() => choose("unified")}>Unified</button>
            <button type="button" role="tab" class={layout.value === "sideBySide" ? "on" : ""} aria-selected={layout.value === "sideBySide"} onClick={() => choose("sideBySide")}>Side by Side</button>
          </span>
        )}
        <button type="button" class="prominent" onClick={() => { layer.diff.value = null; }}>Done</button>
      </header>
      <div class="scroll" ref={body}>
        <div class="review-body">
          <div class="review-diff-head">
            <span>{diff.files.length} {diff.files.length === 1 ? "file" : "files"} changed</span>
            <span class="quiet small counts" aria-label={`${added} lines added, ${removed} removed`}>+{added} −{removed}</span>
            <span class="spacer" />
            {diff.url && <button type="button" onClick={() => openLink(diff.url!)}>Open on GitHub</button>}
          </div>
          {diff.cut && <p class="quiet small">The diff is too long to show every file here. A file with no lines below is on GitHub.</p>}
          {diff.files.map((f, i) => (
            <section class="view-diff-file" data-path={f.path} key={f.path}>
              <div class="review-diff-head">
                <strong class="small path">{f.previousPath ? `${f.previousPath} → ${f.path}` : f.path}</strong>
                {f.change !== "modified" && <span class="quiet small">{f.change}</span>}
                <span class="spacer" />
                <span class="quiet small counts" aria-label={`${f.additions} lines added, ${f.deletions} removed`}>+{f.additions} −{f.deletions}</span>
              </div>
              {rows[i]?.length ? <FileDiff rows={rows[i]!} layout={wide.value ? layout.value : "unified"} />
                : <p class="quiet small">{f.note ?? "No lines to show."}</p>}
            </section>
          ))}
        </div>
      </div>
    </div>
  );
}

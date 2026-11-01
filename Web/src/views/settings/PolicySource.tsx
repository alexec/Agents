// Where this comes from (#2957, FR-020, frame B): every layer of one rule from the top down, with its value or
// "Not set", the layer that decides lit, a capped value marked "Kept, not used", and a folder's layer named by its
// file, committed with the folder's code. The window's and the Remote's is Shared/UI/PolicySourcePopover.swift.
import type { EffectiveRule } from "../../protocol/generated";
import { decides, folderFile, keptNotUsed, layerLine, type Row } from "../../model/policyLayers";

export function PolicySource({ row, rule }: { row: Row; rule: EffectiveRule }) {
  const same = (a: { kind: string; name: string }, b?: { kind: string; name: string }) => b !== undefined && a.kind === b.kind && a.name === b.name;
  return (
    <ol class="policy-source" aria-label={`${row.title}: where this comes from`}>
      {rule.layers.map((l, i) => {
        const lit = same(l.layer, rule.decides);
        return (
          <li key={i} class={lit ? "policy-source-lit" : ""}>
            <span>
              <span class={lit ? "strong" : ""}>{layerLine(l.layer)}</span>
              {l.layer.kind === "folder" && <><br /><span class="quiet small">{folderFile}</span></>}
            </span>
            <span class="policy-source-value">
              <span class={l.value === undefined ? "quiet" : ""}>{l.words}</span>
              {lit ? <><br /><span class="small strong">{decides}</span></> : l.kept && <><br /><span class="quiet small">{keptNotUsed}</span></>}
            </span>
          </li>
        );
      })}
      {!rule.decides && <li class="quiet small">No layer sets this: {row.unset}.</li>}
    </ol>
  );
}

// Ask before use (#4016) on a sheet that adds or replaces a secret: the checkbox, and under it what
// on and off mean. As the window's AskBeforeUseToggle (Shared/UI/AskBeforeUseToggle.swift).
import type { Signal } from "@preact/signals";
import { askBeforeUseHint, askBeforeUseWords } from "../model/askBeforeUse";

export function AskBeforeUseCheck({ on }: { on: Signal<boolean> }) {
  return (
    <>
      <label>
        <input type="checkbox" checked={on.value} onChange={(e) => (on.value = (e.currentTarget as HTMLInputElement).checked)} />
        {" "}{askBeforeUseWords.toggle}
      </label>
      <p class="sheet-note">{askBeforeUseHint(on.value)}</p>
    </>
  );
}

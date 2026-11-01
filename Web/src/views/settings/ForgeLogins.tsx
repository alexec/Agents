// Settings ▸ Control plane ▸ GitHub, GitLab and Linear (#3160), as the window's Settings ▸ Account has them (#2951).
// Saved on Return or on leaving a field, as the window saves. Listed in ./sections.ts.
import { useEffect } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { Store } from "../../model/store";
import type { ForgeLogins } from "../../protocol/generated";
import { CallFailed } from "../../wire/link";
import { methodNotFound } from "../../model/errors";
import { forgeLoginFields, forgeLoginsFooter, forgeLoginsNotSaved, forgeLoginsTitle, loginsChanged, loginsToSave, myLogins } from "../../model/forgeLogins";

export function ForgeLoginsSection({ store, down }: { store: Store; down: boolean }) {
  // Null until people/forViews answers, so a save before then cannot clear what is kept.
  const kept = useSignal<Required<ForgeLogins> | null>(null);
  const typed = useSignal<Required<ForgeLogins>>({ github: "", gitlab: "", linear: "" });
  const unknown = useSignal(false);
  const problem = useSignal("");

  useEffect(() => {
    if (down) return;
    store.link.call("people/forViews", {})
      .then((list) => { const mine = myLogins(list); kept.value = mine; typed.value = mine; })
      // A control plane from before #2951 has no logins to keep.
      .catch((error) => { if (error instanceof CallFailed && error.code === methodNotFound) unknown.value = true; });
  }, [store, down]);

  if (unknown.value) return null;

  const save = async () => {
    if (!kept.value || !loginsChanged(kept.value, typed.value)) return;
    const next = loginsToSave(typed.value);
    try {
      await store.link.call("people/setForgeLogins", next);
      kept.value = next;
      problem.value = "";
    } catch {
      problem.value = forgeLoginsNotSaved;
    }
  };

  return (
    <section aria-labelledby="settings-forge-logins">
      <h3 class="section-head" id="settings-forge-logins">{forgeLoginsTitle}</h3>
      {forgeLoginFields.map(({ key, label }) => (
        <label class="setting" key={key}>
          <span>{label}</span>
          <input type="text" spellcheck={false} autocomplete="off" placeholder="Not given" value={typed.value[key]}
            disabled={down || !kept.value}
            onInput={(e) => (typed.value = { ...typed.value, [key]: e.currentTarget.value })}
            onChange={() => void save()} />
        </label>
      ))}
      {problem.value && <p class="hint failure" role="alert">{problem.value}</p>}
      <p class="hint">{forgeLoginsFooter}</p>
    </section>
  );
}

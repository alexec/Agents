// Settings ▸ This device ▸ Appearance: the icon's mood (#1317) and Show thoughts (#1725). Listed in ./sections.ts.
import { iconShowsMood, setIconShowsMood } from "../../model/iconMood";
import { setShowsThoughts, showsThoughts, thoughtsFooter } from "../../model/thoughts";

/** The words under the icon's mood (#1317), for this tab's favicon. */
export const iconMoodFooter = "The Blob on this tab sleeps when nothing runs, smiles while agents work, and looks "
  + "puzzled when a question waits. Off, it always smiles.";

export function AppearanceSection() {
  return (
    <section aria-labelledby="settings-appearance">
      <h3 class="section-head" id="settings-appearance">Appearance</h3>
      <label class="setting">
        <span>Icon shows what agents are doing</span>
        <input type="checkbox" role="switch" checked={iconShowsMood.value}
          onChange={(e) => setIconShowsMood(e.currentTarget.checked)} />
      </label>
      <p class="hint">{iconMoodFooter}</p>
      <label class="setting">
        <span>Show thoughts</span>
        <input type="checkbox" role="switch" checked={showsThoughts.value}
          onChange={(e) => setShowsThoughts(e.currentTarget.checked)} />
      </label>
      <p class="hint">{thoughtsFooter}</p>
    </section>
  );
}

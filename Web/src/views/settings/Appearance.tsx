// Settings ▸ This device ▸ Appearance: Show thoughts (#1725). The favicon always shows the
// agents' mood (#1317), with no switch (#2156). Listed in ./sections.ts.
import { setShowsThoughts, showsThoughts, thoughtsFooter } from "../../model/thoughts";

export function AppearanceSection() {
  return (
    <section aria-labelledby="settings-appearance">
      <h3 class="section-head" id="settings-appearance">Appearance</h3>
      <label class="setting">
        <span>Show thoughts</span>
        <input type="checkbox" role="switch" checked={showsThoughts.value}
          onChange={(e) => setShowsThoughts(e.currentTarget.checked)} />
      </label>
      <p class="hint">{thoughtsFooter}</p>
    </section>
  );
}

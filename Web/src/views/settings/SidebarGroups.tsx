// Settings ▸ You ▸ Sidebar (#846, #2079): which smart groups are on, the person's and the same on every
// client (#1033). Listed in ./sections.ts.
import { smartRows, smartTitles } from "../../model/sidebar";
import { setSmartGroup, smartGroupsOn } from "../../model/smartGroups";

/** The words under the Sidebar section, as the window's and the Remote's (#846). */
export const sidebarSettingsFooter = "A group that is off is not shown. Its sessions go to the next group they fit, "
  + "or under their folder. With Needs You off, approvals are not listed in the sidebar. The same on every client of yours.";

export function SidebarGroupsSection() {
  const on = smartGroupsOn.value;
  return (
    <section aria-labelledby="settings-sidebar">
      <h3 class="section-head" id="settings-sidebar">Sidebar</h3>
      {smartRows.map((row) => (
        <label class="setting" key={row}>
          <span>{smartTitles[row]}</span>
          <input type="checkbox" role="switch" checked={on.has(row)}
            onChange={(e) => setSmartGroup(row, e.currentTarget.checked)} />
        </label>
      ))}
      <p class="hint">{sidebarSettingsFooter}</p>
    </section>
  );
}

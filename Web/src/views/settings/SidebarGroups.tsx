// Settings ▸ You ▸ Sidebar (#846, #2079): which smart groups are on, and whether a project's sessions go
// under a Sessions row (#2312), the person's and the same on every client (#1033). Listed in ./sections.ts.
import { folds } from "../../model/folds";
import { smartRows, smartTitles } from "../../model/sidebar";
import { setSmartGroup, smartGroupsOn } from "../../model/smartGroups";

/** The words under the Sidebar section, as the window's and the Remote's (#846). */
export const sidebarSettingsFooter = "A group that is off is not shown. Its sessions go to the next group they fit, "
  + "or under their project. With Needs You off, approvals are not listed in the sidebar. The same on every client of yours.";

/** The words under the Sessions row's switch (#2312), as the window's and the Remote's. */
export const groupsSessionsFooter = "On, a project's sessions fold under a Sessions row, as its workflows fold under "
  + "Workflows. Off, they are listed straight under the project. The same on every client of yours.";

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
      <label class="setting">
        <span>Group sessions under a Sessions row</span>
        <input type="checkbox" role="switch" checked={folds.groupsSessions.value}
          onChange={(e) => folds.setGroupsSessions(e.currentTarget.checked)} />
      </label>
      <p class="hint">{groupsSessionsFooter}</p>
    </section>
  );
}

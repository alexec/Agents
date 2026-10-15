// This browser's Settings (#846), opened from the sidebar's foot, in the chat's place: what the
// window has in Settings ▸ Appearance and Settings ▸ Sidebar. Celebrations (#986) is this
// browser's alone, in its localStorage; which smart groups are on is the person's, kept on their
// Mac and the same on every client (#1033).
import { smartRows, smartTitles } from "../model/sidebar";
import { setSmartGroup, smartGroupsOn } from "../model/smartGroups";
import { BackToList } from "./BackToList";
import { celebrationsOn, setCelebrations } from "../model/celebrations";

/** The words under the Sidebar section, as the window's and the Remote's (#846). */
export const sidebarSettingsFooter = "A group that is off is not shown. Its sessions go to the next group they fit, "
  + "or under their project. With Needs You off, approvals are not listed in the sidebar.";

/** The words under Celebrations (#986), as the window's and the Remote's. */
export const celebrationsFooter = "Celebrations: the Blob hops when a pull request lands, with confetti for the day's first "
  + "and for a milestone. No sound; Reduce Motion keeps it still.";

export function SettingsPage() {
  const on = smartGroupsOn.value;
  return (
    <section class="chat activity-page settings-page" aria-label="Settings">
      <header class="column-head"><BackToList /><h1>Settings</h1></header>
      <div class="scroll">
        <div class="activity-body settings-body">
          <section aria-labelledby="settings-appearance">
            <h2 class="section-head" id="settings-appearance">Appearance</h2>
            <label class="setting">
              <span>Celebrations</span>
              <input type="checkbox" role="switch" checked={celebrationsOn.value}
                onChange={(e) => setCelebrations(e.currentTarget.checked)} />
            </label>
            <p class="hint">{celebrationsFooter}</p>
          </section>
          <section aria-labelledby="settings-sidebar">
            <h2 class="section-head" id="settings-sidebar">Sidebar</h2>
            {smartRows.map((row) => (
              <label class="setting" key={row}>
                <span>{smartTitles[row]}</span>
                <input type="checkbox" role="switch" checked={on.has(row)}
                  onChange={(e) => setSmartGroup(row, e.currentTarget.checked)} />
              </label>
            ))}
            <p class="hint">{sidebarSettingsFooter}</p>
          </section>
        </div>
      </div>
    </section>
  );
}

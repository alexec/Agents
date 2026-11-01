// Settings ▸ This browser ▸ Notifications: whether this page may show notices, while it is open and in front (#2860),
// and by Web Push when no iPhone gets them (#1486). How many notices agents may send is a rule of Agents ▸ Policy
// now (#2957, FR-023), kept on the Mac's host. Listed in ./sections.ts.
import { allowPageNotices, pagePermission, pagePermissionText, webPush, webPushText } from "../../pageNotices";

export function NotificationsSection() {
  return (
    <section aria-labelledby="settings-notifications">
      <h3 class="section-head" id="settings-notifications">Notifications</h3>
      <div class="setting">
        <span>This page</span>
        {pagePermission.value === "default" && <button type="button" onClick={() => void allowPageNotices()}>Allow Notifications</button>}
      </div>
      <p class="hint">{pagePermissionText(pagePermission.value)}</p>
      {webPushText(webPush.value) && <p class="hint">{webPushText(webPush.value)}</p>}
      <p class="hint">How many notices agents may send is in Agents ▸ Policy.</p>
    </section>
  );
}

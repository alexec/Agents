// This browser's Settings (#846), opened from the sidebar's foot, in the chat's place: what the
// window has in Settings ▸ Appearance and Settings ▸ Sidebar. Celebrations (#986) is this
// browser's alone, in its localStorage; which smart groups are on is the person's, kept on their
// Mac and the same on every client (#1033). Slack (#1009) is the control plane's: where agents'
// questions go when the person is away from their Mac.
import { useEffect, useState } from "preact/hooks";
import type { SlackState } from "../protocol/generated";
import type { Store } from "../model/store";
import { describe } from "../model/errors";
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

/** The line under the Slack heading (#1009). */
export const slackSettingsFooter = "Answer agents' questions from Slack. Questions go to your direct messages when you are away from your Mac.";

/** The how-to for Slack (#1009), on GitHub. */
export const slackSetUpURL = "https://github.com/alexec/Agents/blob/main/docs/how-to/answer-questions-from-slack.md";

/** What the Slack status line says (#1009). */
export function slackStatusLine(slack: SlackState): string {
  if (!slack.available) return slack.detail ?? "Slack is not available.";
  switch (slack.status) {
    case "connected": return "Connected";
    case "connecting": return "Connecting…";
    case "off": return "Off";
    default: return slack.detail ? `Not connected: ${slack.detail}` : "Not connected";
  }
}

/**
 * Slack (#1009): a switch, the member ID and the two tokens, then Save. A token field is never
 * filled from the control plane; it only says whether one is set. Only a token the person typed
 * is sent, and the field is cleared after a good save.
 */
function SlackSection({ store }: { store: Store }) {
  useEffect(() => { void store.loadChannels(); }, []);
  const slack = store.channels.value?.slack ?? null;
  // What the person changed and has not saved yet; null means "as the control plane says".
  const [enabled, setEnabled] = useState<boolean | null>(null);
  const [memberID, setMemberID] = useState<string | null>(null);
  const [appToken, setAppToken] = useState("");
  const [botToken, setBotToken] = useState("");
  const [saving, setSaving] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);
  const off = !slack || !slack.available || saving;

  async function save() {
    const change: { enabled?: boolean; memberID?: string; appToken?: string; botToken?: string } = {};
    if (enabled !== null) change.enabled = enabled;
    if (memberID !== null) change.memberID = memberID.trim();
    if (appToken.trim()) change.appToken = appToken.trim();
    if (botToken.trim()) change.botToken = botToken.trim();
    setSaving(true);
    setProblem(null);
    try {
      await store.setChannels({ slack: change });
      setEnabled(null);
      setMemberID(null);
      setAppToken("");
      setBotToken("");
    } catch (error) {
      setProblem(describe(error));
    } finally {
      setSaving(false);
    }
  }

  return (
    <section aria-labelledby="settings-slack">
      <h2 class="section-head" id="settings-slack">Slack</h2>
      <p class="hint">
        {slackSettingsFooter}{" "}
        <a href={slackSetUpURL} target="_blank" rel="noopener noreferrer">Set-up steps</a>
      </p>
      {slack && slack.available && (
        <form onSubmit={(e) => { e.preventDefault(); void save(); }}>
          <label class="setting">
            <span>Send questions to Slack</span>
            <input type="checkbox" role="switch" disabled={off} checked={enabled ?? slack.enabled}
              onChange={(e) => setEnabled(e.currentTarget.checked)} />
          </label>
          <label class="setting">
            <span>Slack member ID</span>
            <input type="text" placeholder="U…" autoComplete="off" spellcheck={false} disabled={off}
              value={memberID ?? slack.memberID} onInput={(e) => setMemberID(e.currentTarget.value)} />
          </label>
          <label class="setting">
            <span>App token <span class="faint small">{slack.appTokenSet ? "Set" : "Not set"}</span></span>
            <input type="password" placeholder="xapp-…" autoComplete="off" disabled={off}
              value={appToken} onInput={(e) => setAppToken(e.currentTarget.value)} />
          </label>
          <label class="setting">
            <span>Bot token <span class="faint small">{slack.botTokenSet ? "Set" : "Not set"}</span></span>
            <input type="password" placeholder="xoxb-…" autoComplete="off" disabled={off}
              value={botToken} onInput={(e) => setBotToken(e.currentTarget.value)} />
          </label>
          <div class="setting">
            <span class="faint small" role="status">{slackStatusLine(slack)}</span>
            <button type="submit" disabled={off}>Save</button>
          </div>
          {problem && <p class="failure small" role="alert">{problem}</p>}
        </form>
      )}
      {slack && !slack.available && <p class="hint" role="status">{slackStatusLine(slack)}</p>}
    </section>
  );
}

export function SettingsPage({ store }: { store: Store }) {
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
          <SlackSection store={store} />
        </div>
      </div>
    </section>
  );
}

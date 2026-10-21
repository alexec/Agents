// Settings ▸ This device ▸ Finished chats. Listed in ./sections.ts.
import { mayArchiveMyChats, mayArchiveMyChatsFooter, setMayArchiveMyChats } from "../../model/fileToSeeWords";

export function FinishedChatsSection() {
  return (
    <section aria-labelledby="settings-finished">
      <h3 class="section-head" id="settings-finished">Finished chats</h3>
      <label class="setting">
        <span>Agents may archive the chats I start</span>
        <input type="checkbox" role="switch" checked={mayArchiveMyChats.value}
          onChange={(e) => setMayArchiveMyChats(e.currentTarget.checked)} />
      </label>
      <p class="hint">{mayArchiveMyChatsFooter}</p>
    </section>
  );
}

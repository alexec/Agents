// The files pane's place (071 US6 scenario 1, frame B): a fourth column from 1440, over the chat
// below that, with a close button. Its contents (files, changes, a live page) come in US4.
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { Model } from "../model";
import type { DirectoryEntry } from "../protocol/generated";
import { replace, route } from "../route";

export function FilesPane({ model, host, session }: { model: Model; host: string; session: string }) {
  const entries = useSignal<DirectoryEntry[]>([]);
  useEffect(() => {
    entries.value = [];
    void model.link.call("files/list", { agentID: session as never, folder: "" }, host)
      .then((listing) => (entries.value = listing.entries), () => {});
  }, [host, session]);
  return (
    <aside class="files" aria-label="Files">
      <header class="column-head">
        <span class="tabs"><span class="tab chosen">Files</span></span>
        <button class="icon" aria-label="Close Files" onClick={() => replace({ ...route.value, files: false })}>✕</button>
      </header>
      <ul class="scroll">
        {entries.value.map((entry) => <li key={entry.url}>{entry.name}{entry.isDirectory ? "/" : ""}</li>)}
      </ul>
    </aside>
  );
}

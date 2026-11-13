// An agent whose folder has gone (#119): a strip across the top of its chat saying which folder,
// with the ways on, as the window's MissingFolderStrip; a refused send is the same strip, carrying
// what was typed (#5034). The prompt keeps the words either way.
import type { Agent, Attachment } from "../protocol/generated";
import type { Store } from "../model/store";
import { go } from "../route";
import { archiveWithChildren } from "./SessionMenu";
import { Strip } from "./Strip";
import {
  continueInFolderLabel, folderIsMissing, folderPath, mayRecreateWorktree, missingFolderLabel, recreateWorktreeLabel,
} from "../model/missingFolder";

async function continueIn(store: Store, host: string, agent: Agent, text = "", attachments: Attachment[] = []) {
  const id = await store.continueInFolder(host, agent.id, text, attachments);
  if (id) go({ host, folder: agent.worktree?.folder || agent.cwd, session: id });
}

export const typedIsKept = "What you typed is still in the prompt.";

/** Whether the session has a folder strip: its folder has gone, or a send was refused for it. */
export function folderStripApplies(store: Store, host: string, agent: Agent | undefined): boolean {
  if (!agent || agent.state === "archived") return false;
  const ask = store.folderGone.value;
  return folderIsMissing(agent) || (!!ask && ask.host === host && ask.agentID === agent.id);
}

/** The folder's strip (#5034, second of the session's strips; #119): which folder, and the ways on. A send
 *  the host refused because the folder went is this strip too: it says what was typed is still in the
 *  prompt, and Continue in the folder takes it along. It was a notice of its own over this strip. */
export function MissingFolderStrip({ store, host, agent }: { store: Store; host: string; agent: Agent | undefined }) {
  if (!agent || !folderStripApplies(store, host, agent)) return null;
  const ask = store.folderGone.value;
  const refused = ask && ask.host === host && ask.agentID === agent.id ? ask : null;
  const close = () => { if (refused) store.folderGone.value = null; };
  return (
    <Strip tone="warning" name={`missing-folder-strip${refused ? " folder-gone" : ""}`} icon="folder-search"
      line={missingFolderLabel} detail={refused ? `${folderPath(agent)} · ${typedIsKept}` : folderPath(agent)}
      title={refused ? `${refused.message} ${typedIsKept}` : folderPath(agent)}
      primary={{ label: continueInFolderLabel, run: () => { close(); void continueIn(store, host, agent, refused?.text, refused?.attachments); } }}
      second={{ label: "Archive", run: () => { close(); void archiveWithChildren(store, host, agent); } }}
      more={mayRecreateWorktree(agent)
        ? [{ label: recreateWorktreeLabel, run: () => { close(); void store.recreateWorktree(host, agent.id); } }] : []} />
  );
}

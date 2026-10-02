// An agent whose folder has gone (#119): a strip across the top of its chat saying which folder,
// with the ways on, as the window's MissingFolderStrip; and the refusal of a send, said with the
// same ways on and carrying what was typed. The prompt keeps the words either way.
import type { Agent, Attachment } from "../protocol/generated";
import type { Store } from "../model/store";
import { go } from "../route";
import {
  continueInProjectLabel, folderIsMissing, folderPath, mayRecreateWorktree, missingFolderLabel, recreateWorktreeLabel,
} from "../model/missingFolder";

async function continueIn(store: Store, host: string, agent: Agent, text = "", attachments: Attachment[] = []) {
  const id = await store.continueInProject(host, agent.id, text, attachments);
  if (id) go({ host, project: agent.worktree?.project ?? agent.cwd, session: id });
}

function WaysOn({ store, host, agent, text, attachments, then }: {
  store: Store; host: string; agent: Agent; text?: string; attachments?: Attachment[]; then?: () => void;
}) {
  return (
    <span class="ways-on">
      <button onClick={() => { then?.(); void continueIn(store, host, agent, text, attachments); }}>{continueInProjectLabel}</button>
      {mayRecreateWorktree(agent) && (
        <button onClick={() => { then?.(); void store.recreateWorktree(host, agent.id); }}>{recreateWorktreeLabel}</button>
      )}
      <button onClick={() => { then?.(); void store.perform(host, agent.id, "agents/archive"); }}>Archive</button>
    </span>
  );
}

export function MissingFolderStrip({ store, host, agent }: { store: Store; host: string; agent: Agent | undefined }) {
  if (!agent || !folderIsMissing(agent)) return null;
  return (
    <div class="missing-folder-strip" role="status">
      <span class="what" title={folderPath(agent)}>⚠ {missingFolderLabel} <span class="quiet">· {folderPath(agent)}</span></span>
      {/* Once, not twice: a refused send's notice above has the same ways on. */}
      {store.folderGone.value?.agentID !== agent.id && <WaysOn store={store} host={host} agent={agent} />}
    </div>
  );
}

/** A send refused because the folder has gone, for the open chat: the host's words and the ways on. */
export function FolderGoneNotice({ store, host, agent }: { store: Store; host: string; agent: Agent | undefined }) {
  const ask = store.folderGone.value;
  if (!ask || !agent || ask.host !== host || ask.agentID !== agent.id) return null;
  const close = () => { store.folderGone.value = null; };
  return (
    <div class="problem folder-gone" role="alert">
      <span>{ask.message} What you typed is still in the prompt.</span>
      <span class="ways-on">
        <WaysOn store={store} host={host} agent={agent} text={ask.text} attachments={ask.attachments} then={close} />
        <button class="link" onClick={close}>Cancel</button>
      </span>
    </div>
  );
}

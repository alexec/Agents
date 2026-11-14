// A machine's worktrees on its page (#790, #3627), as the window's MachineWorktreesSections:
// the host's folders' worktrees and how much each holds, idle ones first, largest first, sizes
// filling in as the host measures them (worktrees/sized). Remove build output and Remove… on an
// idle worktree the app made; Clean up worktrees per folder opens its new session with the words.
import { useEffect, useState } from "preact/hooks";
import type { Store } from "../model/store";
import type { WorktreeSummary } from "../protocol/generated";
import { folderKey } from "../model/groups";
import { newSessionDraftKey } from "../model/drafts";
import {
  cleanUpDraft, folderLine, forCleanup, freedWords, isIdle, measuring, removalMessage, sizeWords, worktreeDetail,
} from "../model/worktrees";
import { ask } from "./MessageKinds";

/** One host's worktrees, a row per folder with its count, closed until the person opens it (#3743). */
export function WorktreesList({ store, host }: { store: Store; host: string }) {
  useEffect(() => { void store.loadWorktrees(host); }, [host]);
  const groups = forCleanup(store.worktreeLists.value[host] ?? [], store.worktreeSizes.value[host]);
  const folderName = (folder: string) =>
    store.folders.value[host]?.find((p) => folderKey(p.folder.folder) === folderKey(folder))?.name
      ?? decodeURIComponent(folder.replace(/\/$/, "").split("/").pop() ?? folder);
  const cleanUp = (folder: string) => {
    const project = store.folders.value[host]?.find((p) => folderKey(p.folder.folder) === folderKey(folder))?.project;
    const key = newSessionDraftKey(host, folderKey(folder), project);
    store.drafts.set(key, cleanUpDraft(store.drafts.get(key)));
    // The hash the router reads, as Activity's navigate writes one: importing the router here would
    // have it read the location as the module loads.
    location.hash = "#/" + ["h", host, "p", folder, "n", "1"].map(encodeURIComponent).join("/");
  };
  return (
    <div class="resources worktrees">
      {groups.map((group) => (
        <details class="machine-fold" key={group.folder}>
          <summary>{folderLine(folderName(group.folder), group.worktrees.length)}</summary>
          <p class="worktrees-head">
            <span />
            <button class="small" title="A new session here, offered the words to remove what has been merged"
              onClick={() => cleanUp(group.folder)}>Clean up worktrees</button>
          </p>
          <ul>
            {group.worktrees.map((w) => <WorktreeItem key={w.root} store={store} host={host} folder={group.folder} worktree={w} />)}
          </ul>
        </details>
      ))}
    </div>
  );
}

function WorktreeItem({ store, host, folder, worktree }: {
  store: Store; host: string; folder: string; worktree: WorktreeSummary;
}) {
  const [busy, setBusy] = useState(false);
  const [freed, setFreed] = useState<string | null>(null);
  const canClean = worktree.madeByApp && worktree.exists && isIdle(worktree);
  const down = !store.hostIsOnline(host);
  const removeBuildOutput = async () => {
    setBusy(true);
    const removed = await store.removeBuildOutput(host, folder, worktree.root);
    if (removed) setFreed(freedWords(removed));
    setBusy(false);
  };
  // Asked first, always; removed straight away only when nothing would be lost, as the window does.
  const remove = async () => {
    setBusy(true);
    const check = await store.checkWorktreeRemoval(host, folder, worktree.root);
    if (check && check.blockedBy.length === 0) {
      const loses = check.uncommitted > 0 || check.unmerged;
      if (!loses) await store.removeWorktree(host, folder, worktree.root, false);
      else if (await ask(`Remove ${worktree.name}?\n\n${removalMessage(check, worktree.branch)}`)) {
        await store.removeWorktree(host, folder, worktree.root, true);
      }
    } else if (check) {
      const names = check.blockedBy.map((id) => (store.agents.value[host] ?? []).find((a) => a.id === id)?.title ?? "An agent");
      store.say(`Still working in ${worktree.name}: ${names.join(", ")}. Archive them first.`);
    }
    setBusy(false);
  };
  return (
    <li class="resource worktree" title={worktree.root}>
      <p>
        <span class={`strong${worktree.exists ? "" : " struck"}`}>{worktree.name}</span>
        {worktree.exists && (
          <span class={`worktree-size small${worktree.size ? " quiet" : " faint"}`}>
            {worktree.size ? sizeWords(worktree.size) : measuring}
          </span>
        )}
      </p>
      <p class="quiet small">{worktree.exists ? worktreeDetail(worktree) : `${worktree.branch ?? "detached"} · its folder is gone`}</p>
      {freed && <p class="quiet small">{freed}</p>}
      {canClean && (
        <p class="worktree-actions">
          <button disabled={busy || down} title="Delete build, .build, DerivedData, node_modules, target and dist that git ignores"
            onClick={() => void removeBuildOutput()}>Remove build output</button>{" "}
          <button disabled={busy || down} onClick={() => void remove()}>Remove…</button>
        </p>
      )}
    </li>
  );
}

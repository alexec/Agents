// One workflow, opened in the chat's place (#98, #100, #142; the window's WorkflowPage and the
// Remote's), in their order: its name and what it is; Run Now or Approve, the Enabled switch and
// Archive or Unarchive; the status card, why it is or isn't running; a file that cannot be read,
// as it is (#540); what it does (who gets the prompt and, for a standing one, its agent; the
// prompt; its settings; its labels); what makes it run, a line a trigger, its cooldown, and which
// computers run it; what its file says that this version does not know; and the sessions it
// started. Every attribute is shown; the settings, labels, cooldown and hosts are edited here as in
// the window (#162, #317), what the workflow is (name, triggers, prompt, agent mode) is not.
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { Agent } from "../protocol/generated";
import type { Store } from "../model/store";
import {
  cooldownSentence, labelsNote, mcpMissedWords, mcpTriggerWords, agentModeWords, unknownLines, isUnapproved, canBeApproved, canBeDenied, workflowStatusLines, isOn, isSupportedTrigger, switchesSentence, scopeSentence, lastRanLine, nextLine, resumedAgent, scopeLine, triggerFilters, triggerGlyph,
  runsOnParts, triggerSummary, workflowRunsOnSentence, workflowHostChoices, workflowSummary,
} from "../model/workflows";
import { go } from "../route";
import { RunNow } from "./WorkflowRow";
import { rowExtras, SessionRow } from "./SessionRow";
import { CooldownMenu, WhenDoneMenu, WorkflowSettingsForm } from "./WorkflowSettings";
import { picked, whenDoneSentence } from "../model/workflowSettings";
import { workflowContinueSentence, workflowContinueSwitch } from "../model/continueWhenBack";
import { BackToList } from "./BackToList";
import { isWorkflowMuted, muteLabel, workflowMuteHelp } from "../model/mute";
import { Capability } from "../protocol/capabilities.generated";
import { WorkflowFileModal } from "./AgentConfigEditor";
import { PageTitle } from "./TopBar";
import { navTitle } from "../model/nav";

export function WorkflowPage({ store, host, folder, folderName, workflowID, down }: {
  store: Store; host: string; folder: string; folderName: string; workflowID: string; down: boolean;
}) {
  // Held while the page is open, shared with the sidebar's fold, and let go by the last of them (#291).
  useEffect(() => {
    store.holdWorkflows(host, folder);
    return () => store.releaseWorkflows(host, folder);
  }, [host, folder]);
  const known = store.workflowsKnown(host, folder);
  const summary = store.folderWorkflows(host, folder).find((w) => w.workflow.workflowID === workflowID);
  // Which half of the page is on show (#863), as the window and the Remote have it.
  const pane = useSignal<"activity" | "configuration">("activity");
  // Its file, up in the Workflows editor (#2803).
  const editsFile = useSignal(false);
  const runLimit = useSignal(3);
  const runs = useSignal<Agent[]>([]);
  const loadingRuns = useSignal(false);
  useEffect(() => {
    let current = true;
    loadingRuns.value = true;
    void store.loadWorkflowRuns(host, folder, workflowID, runLimit.value).then((listed) => {
      if (current) { runs.value = listed; loadingRuns.value = false; }
    });
    return () => { current = false; };
  }, [host, folder, workflowID, runLimit.value]);
  // The daemon's refusal of the last change, said beside the controls until the next one.
  const problem = useSignal<{ workflowID: string; text: string } | null>(null);
  // "Checked 20 s ago" under a server's event trigger (#383) moves on the page's own clock.
  const now = useSignal(new Date());
  useEffect(() => {
    const timer = setInterval(() => { now.value = new Date(); }, 10_000);
    return () => clearInterval(timer);
  }, []);
  const back = <BackToList />;
  if (!known) {
    return (
      <section class="chat workflow-page" aria-label="Workflow">
        <header class="column-head">{back}<h1>Workflow</h1></header>
        <p class="hint">Loading…</p>
      </section>
    );
  }
  if (!summary) {
    return (
      <section class="chat workflow-page" aria-label="Workflow">
        <header class="column-head">{back}<h1>Workflow</h1></header>
        <p class="hint">This workflow is no longer there. Its file has been removed or renamed.</p>
      </section>
    );
  }
  const workflow = summary.workflow;
  const hostName = store.isMac(host) ? "this Mac" : store.hosts.value.find((h) => h.id === host)?.name ?? host;
  const runtimeName = (id: string) => (store.runtimes.value[host] ?? []).find((r) => r.runtime.id === id)?.runtime.name;
  const status = workflowStatusLines(summary);
  const standing = workflow.mode === "standing" && summary.standingAgentID
    ? [store.agent(host, summary.standingAgentID)].find((a) => a !== undefined && a.archivedAt === undefined) : undefined;
  const cooldown = cooldownSentence(summary);
  const unknown = unknownLines(workflow);
  const choices = workflowHostChoices(store.hosts.value, store.macHostID.value);
  const knownHosts = new Set(choices.map((choice) => choice.machineID));
  const { machines: pinned, needs } = runsOnParts(workflow.runsOn, knownHosts);
  const rows = [...choices, ...pinned.filter((id) => !knownHosts.has(id)).map((id) => ({ machineID: id, name: id }))];
  // A file that could not be read has no settings to show, so a change would write the empty ones.
  const locked = down || workflow.problem !== undefined;
  const change = (what: Parameters<Store["setWorkflowSettings"]>[2]) =>
    void store.setWorkflowSettings(host, summary, what).then((refusal) => { problem.value = refusal ? { workflowID, text: refusal } : null; });
  const deleteWorkflow = async () => {
    if (confirm(`Delete "${workflow.name}"? Its file is removed from disk.\n\nThe file can be restored from the folder's git history.`)) {
      if (await store.deleteWorkflow(host, summary)) go({ host, folder: folder });
    }
  };
  // Yours are in ~/.agents on the Mac, as Settings ▸ Agent Configuration edits them; the folder's on its host.
  const yours = summary.scope === "user";
  const editFile = <button class="archive" disabled={down}
    title={yours ? "Open this workflow's file in Settings ▸ Agent Configuration ▸ Workflows"
      : "Open this workflow's file in the folder's Agent Configuration ▸ Workflows"}
    onClick={() => { editsFile.value = true; }}>Edit File…</button>;
  return (
    <section class="chat workflow-page" aria-label="Workflow">
      <header class="column-head page-head">{back}
        <PageTitle parts={[{ title: navTitle.workflows, to: { nav: "workflows" } }, { title: folderName }, { title: workflow.name }]}><h1>{workflow.name}</h1></PageTitle>
      </header>
      {editsFile.value && <WorkflowFileModal store={store} host={yours ? store.macHostID.value : host}
        folder={yours ? undefined : folder} path={`${workflow.workflowID}.md`} down={down}
        close={() => { editsFile.value = false; }} />}
      <div class="scroll">
        <div class="workflow-body">
          <div class="heading">
            {!workflow.problem && <p class="quiet">{workflowSummary(workflow, runtimeName)}</p>}
            {/* Yours, in every folder (#2759): its rows under a folder do not say so. */}
            {scopeSentence(summary) && <p class="quiet small">{scopeSentence(summary)}</p>}
          </div>
          {summary.isArchived ? (
            <div class="controls">
              <button class="run-now prominent" disabled={down} onClick={() => void store.setWorkflowArchived(host, summary, false)}>Unarchive</button>
              {editFile}
              <button class="archive" disabled={down} title="Delete this workflow file from disk" onClick={() => void deleteWorkflow()}>Delete…</button>
            </div>
          ) : (
            <div class="controls">
              {isUnapproved(summary)
                ? <>
                  {canBeApproved(summary) && (
                    <button class="run-now prominent" disabled={down} title="Let this workflow run as its file now reads"
                      onClick={() => void store.approveWorkflow(host, summary)}>Approve</button>
                  )}
                  {/* Not on this host, without archiving it everywhere (#391). */}
                  {canBeDenied(summary) && (
                    <button class="deny" disabled={down} title="Don't run it on this machine. Other machines still see it waiting; Approve takes this back"
                      onClick={() => void store.denyWorkflow(host, summary)}>Deny on This Machine</button>
                  )}
                </>
                : <RunNow store={store} host={host} summary={summary} disabled={down} wide />}
              {/* Beside Run Now, which still works with it off (#100). */}
              <label class="switch" title={isOn(summary) ? "On: its triggers run it" : "Off: none of its triggers run it; Run Now still does"}>
                <input type="checkbox" role="switch" aria-label="Enabled" checked={isOn(summary)} disabled={down}
                  onChange={(e) => void store.setWorkflowEnabled(host, summary, (e.currentTarget as HTMLInputElement).checked)} />
                Enabled
              </label>
              {/* Its runs still go under Needs You, and send no notifications (#2003). */}
              {store.has(host, Capability.mute1) && (
                <label class="switch" title={workflowMuteHelp(isWorkflowMuted(summary))}>
                  <input type="checkbox" role="switch" aria-label={muteLabel} checked={isWorkflowMuted(summary)} disabled={down}
                    onChange={(e) => void store.setWorkflowMuted(host, summary, (e.currentTarget as HTMLInputElement).checked)} />
                  {muteLabel}
                </label>
              )}
              {/* Pinned to the top of its folder in the sidebar (#432), as the window's page has it. */}
              {(() => {
                const pinned = store.workflowPinsIn(host, folder).includes(workflow.workflowID);
                return (
                  <button class="archive" disabled={down}
                    title={pinned ? "Take this workflow out of Pinned in the sidebar" : "Keep this workflow in Pinned, at the top of its folder in the sidebar"}
                    onClick={() => void store.setWorkflowPinned(host, folder, workflow.workflowID, !pinned)}>{pinned ? "Unpin" : "Pin"}</button>
                );
              })()}
              <button class="archive" disabled={down} title="Archive this workflow and go back to the folder. Writes archived: true into its file"
                onClick={async () => { await store.setWorkflowArchived(host, summary, true); go({ host, folder: folder }); }}>Archive</button>
              {editFile}
              <button class="archive" disabled={down} title="Delete this workflow file from disk" onClick={() => void deleteWorkflow()}>Delete…</button>
            </div>
          )}
          {/* The switches write the workflow's file (#125), the window's words. */}
          {!summary.isArchived && <p class="quiet small">{switchesSentence(summary)}</p>}

          <div class="tabs workflow-panes" role="tablist" aria-label="Show">
            {(["activity", "configuration"] as const).map((p) => (
              <button key={p} role="tab" aria-selected={pane.value === p} class={pane.value === p ? "on" : ""}
                onClick={() => { pane.value = p; }}>{p === "activity" ? "Activity" : "Configuration"}</button>
            ))}
          </div>

          {/* Two panes (#863): what it has done, and how it is set up. */}
          {pane.value === "activity" ? (
            <>
            <h2 class="section-head">Status</h2>
            <ul class="status-card">
              {status.map((line) => (
                <li key={line.glyph + line.text} class={line.tint ? `tinted ${line.tint}` : undefined}>
                  <span class="glyph" aria-hidden="true">{line.glyph}</span>
                  <span class="what">
                    <span>{line.text}</span>
                    {line.detail && <span class="quiet small">{line.detail}</span>}
                  </span>
                  {line.agentID && <button class="link" onClick={() => go({ host, folder: folder, session: line.agentID })}>Open the agent →</button>}
                </li>
              ))}
            </ul>

            {workflow.problem && "unreadable" in workflow.problem && <UnreadableFile store={store} host={host} folder={folder} workflowID={workflowID} />}

            <h2 class="section-head">History</h2>
            <p class="last-ran quiet small">{lastRanLine(summary)}</p>

            {!loadingRuns.value && runs.value.length === 0 && <p class="hint">Nothing has run yet.</p>}
            {runs.value.map((agent) => {
              const pick = picked(agent.auto, (id) => runtimeName(id) ?? id);
              return (
                <div key={agent.id} class="workflow-run">
                  <SessionRow agent={agent} chosen={false} onPick={() => go({ host, folder: folder, session: agent.id })}
                    extras={rowExtras(store, host, agent)} />
                  {pick && <p class="quiet small">{pick}</p>}
                </div>
              );
            })}
            {runs.value.length === runLimit.value && <button class="link" disabled={loadingRuns.value}
              onClick={() => { runLimit.value += 3; }}>Show more</button>}
            </>
          ) : (
            <>
            <h2 class="section-head">What it does</h2>
            <p class="quiet small">.agents/workflows/{workflow.workflowID}.md</p>
            <p class="agent-mode">
              <span>{agentModeWords(workflow.mode)}</span> <code class="quiet">agent: {workflow.mode}</code>
              {workflow.mode === "standing" && (standing
                ? <button class="link" onClick={() => go({ host, folder: folder, session: standing.id })}>{standing.title ?? "Untitled"} →</button>
                : <span class="quiet"> · Started on the next run</span>)}
            </p>
            <pre class="prompt-text">{workflow.prompt || "(no prompt)"}</pre>
            <WorkflowSettingsForm store={store} host={host} summary={summary} disabled={locked} problem={problem.value?.workflowID === workflowID ? problem.value.text : null} change={change} />
            <p class="quiet small">{workflow.problem ? "Its settings can be changed here once its file can be read." : labelsNote(workflow)}</p>

            <h2 class="section-head">Triggers</h2>
            {workflow.triggers.length === 0 ? <p class="hint">{workflow.problem ? "None could be read from the file." : "None: it runs only by hand, with Run Now."}</p> : (
              <ul class="triggers">
                {workflow.triggers.map((trigger, index) => {
                  const filters = triggerFilters(trigger);
                  const scope = scopeLine(trigger, folderName, hostName);
                  return (
                    <li key={index} class="trigger">
                      <span class="glyph" aria-hidden="true">{triggerGlyph(trigger)}</span>
                      <span class="what">
                        <span>{triggerSummary(trigger)}
                          {!isSupportedTrigger(trigger) && (
                            <span class="unknown" title="This version does not know this trigger, so it never runs the workflow"> Unknown</span>
                          )}
                        </span>
                        {filters.length > 0 && (
                          <span class="filters">{filters.map(([k, v]) => <code key={k}>{k}: {v}</code>)}</span>
                        )}
                        {scope && <span class="quiet small">{scope}</span>}
                        {workflow.mode === "triggering" && isSupportedTrigger(trigger) && <span class="quiet small">{resumedAgent(trigger)}</span>}
                      </span>
                      {"schedule" in trigger && <span class="next quiet small">{nextLine(summary, index)}</span>}
                    </li>
                  );
                })}
              </ul>
            )}
            {(summary.mcpTriggers ?? []).length > 0 && (
              <ul class="mcp-triggers">
                {(summary.mcpTriggers ?? []).map((status, index) => {
                  const words = mcpTriggerWords(status, now.value);
                  const missed = mcpMissedWords(status);
                  return (
                    <li key={index}>
                      <span class={`small ${words.tint ?? "quiet"}`}><span class="glyph" aria-hidden="true">⌁</span> {words.text}</span>
                      {missed && (
                        <span class="small attention">{missed}{" "}
                          <button class="link" disabled={down}
                            onClick={() => void store.clearMCPMissed(host, summary, status.name, status.server)}>Clear</button>
                        </span>
                      )}
                    </li>
                  );
                })}
              </ul>
            )}
            <CooldownMenu summary={summary} disabled={locked} change={change} />
            <p class="quiet small">{cooldown ?? "No cooldown: every trigger runs it, one run at a time."}</p>
            {workflow.mode !== "triggering" && (
              <>
                <WhenDoneMenu summary={summary} disabled={locked} change={change} />
                <p class="quiet small">{whenDoneSentence(workflow.whenDone ?? "keep")}</p>
                <label class="setting">
                  <span>{workflowContinueSwitch}</span>
                  <input type="checkbox" role="switch" checked={workflow.continueWhenBack === true} disabled={locked}
                    onChange={(e) => change({ continueWhenBack: e.currentTarget.checked })} />
                </label>
                <p class="quiet small">{workflowContinueSentence(workflow.continueWhenBack === true)}</p>
              </>
            )}

            <h2 class="section-head">Runs on</h2>
            <p class="quiet small">{workflowRunsOnSentence}</p>
            <div class="host-pins">
              <label class="switch">
                <input type="checkbox" role="switch" aria-label="Every machine" checked={pinned.length === 0} disabled={locked || pinned.length === 0}
                  onChange={() => change({ runsOn: needs })} />
                Every machine
              </label>
              {rows.map((row) => (
                <label class="switch" key={row.machineID}>
                  <input type="checkbox" aria-label={row.name} checked={pinned.includes(row.machineID)} disabled={locked}
                    onChange={(event) => {
                      const on = (event.currentTarget as HTMLInputElement).checked;
                      const next = on ? [...pinned, row.machineID] : pinned.filter((id) => id !== row.machineID);
                      change({ runsOn: [...next, ...needs] });
                    }} />
                  {row.name}
                </label>
              ))}
            </div>
            {needs.length > 0 && <p class="quiet small">Also needs: {needs.join(", ")}</p>}

            {unknown.length > 0 && (
              <>
                <h2 class="section-head">From a later version</h2>
                <div class="unknown-keys">
                  <p class="quiet small">This version does not understand these lines in the file. They are kept as they are when the page changes it.</p>
                  {unknown.map((line) => <code key={line}>{line}</code>)}
                </div>
              </>
            )}
            </>
          )}
        </div>
      </div>
    </section>
  );
}

/** A file whose front matter cannot be read is shown as it is, so it can be fixed (#260, #540). */
function UnreadableFile({ store, host, folder, workflowID }: {
  store: Store; host: string; folder: string; workflowID: string;
}) {
  const path = `.agents/workflows/${workflowID}.md`;
  const raw = useSignal<{ text: string; truncated: boolean } | null | undefined>(undefined);
  useEffect(() => {
    let current = true;
    raw.value = undefined;
    store.readPage(host, folder, path).then(
      (r) => { if (current) raw.value = r.kind === "text" ? { text: r.text, truncated: r.isTruncated } : null; },
      () => { if (current) raw.value = null; });
    return () => { current = false; };
  }, [host, folder, path]);
  return (
    <>
      <h2 class="section-head">The file is below</h2>
      {raw.value === undefined ? <p class="hint">Loading…</p>
        : raw.value === null ? <p class="hint">The workflow file could not be read from the machine.</p>
        : <>
            {raw.value.truncated && <p class="quiet small">Only the start of {path} is shown.</p>}
            <pre class="prompt-text">{raw.value.text}</pre>
          </>}
    </>
  );
}

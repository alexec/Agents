// One workflow, opened in the chat's place (#98, #100, #142; the window's WorkflowPage and the
// Remote's), in their order: its name and what it is; Run Now or Approve, the Enabled switch and
// Archive or Bring Back; the status card, why it is or isn't running; what it does (who gets the
// prompt and, for a standing one, its agent; the prompt; its settings; its labels); what makes it
// run, a line a trigger, its cooldown, and which computers run it; what its file says that this
// version does not know; and the sessions it started. Every attribute is shown; the settings,
// labels, cooldown and hosts are edited here as in the window (#162, #317), what the workflow is
// (name, triggers, prompt, agent mode) is not.
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { Agent } from "../protocol/generated";
import type { Store } from "../model/store";
import {
  cooldownSentence, labelsNote, mcpMissedWords, mcpTriggerWords, agentModeWords, unknownLines, waitsItsTurn, workflowStatusLines, isOn, isSupportedTrigger, switchesSentence, lastRanLine, nextLine, resumedAgent, scopeLine, triggerFilters, triggerGlyph,
  triggerSummary, workflowHostChoices, workflowSummary,
} from "../model/workflows";
import { go } from "../route";
import { RunNow } from "./WorkflowRow";
import { rowExtras, SessionRow } from "./SessionRow";
import { CooldownMenu, RuntimeRow, WorkflowSettingsForm } from "./WorkflowSettings";
import { BackToList } from "./BackToList";

export function WorkflowPage({ store, host, folder, projectName, workflowID, down }: {
  store: Store; host: string; folder: string; projectName: string; workflowID: string; down: boolean;
}) {
  // Held while the page is open, shared with the sidebar's fold, and let go by the last of them (#291).
  useEffect(() => {
    store.holdWorkflows(host, folder);
    return () => store.releaseWorkflows(host, folder);
  }, [host, folder]);
  const known = store.workflowsKnown(host, folder);
  const summary = store.projectWorkflows(host, folder).find((w) => w.workflow.workflowID === workflowID);
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
  const hostName = host === "mac" ? "this Mac" : store.hosts.value.find((h) => h.id === host)?.name ?? host;
  const runtimeName = (id: string) => (store.runtimes.value[host] ?? []).find((r) => r.runtime.id === id)?.runtime.name;
  const status = workflowStatusLines(summary);
  const standing = workflow.mode === "standing" && summary.standingAgentID
    ? [store.agent(host, summary.standingAgentID)].find((a) => a !== undefined && a.archivedAt === undefined) : undefined;
  const cooldown = cooldownSentence(summary);
  const unknown = unknownLines(workflow);
  const pinned = workflow.hosts ?? [];
  const choices = workflowHostChoices(store.hosts.value);
  const knownHosts = new Set(choices.map((choice) => choice.machineID));
  const rows = [...choices, ...pinned.filter((id) => !knownHosts.has(id)).map((id) => ({ machineID: id, name: id }))];
  // A file that could not be read has no settings to show, so a change would write the empty ones.
  const locked = down || workflow.problem !== undefined;
  const change = (what: Parameters<Store["setWorkflowSettings"]>[2]) =>
    void store.setWorkflowSettings(host, summary, what).then((refusal) => { problem.value = refusal ? { workflowID, text: refusal } : null; });
  return (
    <section class="chat workflow-page" aria-label="Workflow">
      <header class="column-head">{back}<h1>{workflow.name}</h1></header>
      <div class="scroll">
        <div class="workflow-body">
          <div class="heading">
            {!workflow.problem && <p class="quiet">{workflowSummary(workflow, runtimeName)}</p>}
          </div>
          {summary.isArchived ? (
            <div class="controls">
              <button class="run-now prominent" disabled={down} onClick={() => void store.setWorkflowArchived(host, summary, false)}>Bring Back</button>
            </div>
          ) : (
            <div class="controls">
              {summary.awaitingApproval
                ? !waitsItsTurn(summary) && (
                  <button class="run-now prominent" disabled={down} title="Let this workflow run as its file now reads"
                    onClick={() => void store.approveWorkflow(host, summary)}>Approve</button>
                )
                : <RunNow store={store} host={host} summary={summary} disabled={down} wide />}
              {/* Beside Run Now, which still works with it off (#100). */}
              <label class="switch" title={isOn(summary) ? "On: its triggers run it" : "Off: none of its triggers run it; Run Now still does"}>
                <input type="checkbox" role="switch" aria-label="Enabled" checked={isOn(summary)} disabled={down}
                  onChange={(e) => void store.setWorkflowEnabled(host, summary, (e.currentTarget as HTMLInputElement).checked)} />
                Enabled
              </label>
              <button class="archive" disabled={down} title="Archive this workflow and go back to the project. Writes archived: true into its file"
                onClick={async () => { await store.setWorkflowArchived(host, summary, true); go({ host, project: folder }); }}>Archive</button>
            </div>
          )}
          {/* The switches write the workflow's file (#125), the window's words. */}
          {!summary.isArchived && <p class="quiet small">{switchesSentence(summary)}</p>}

          <h2 class="section-head">Status</h2>
          <ul class="status-card">
            {status.map((line) => (
              <li key={line.glyph + line.text} class={line.tint ? `tinted ${line.tint}` : undefined}>
                <span class="glyph" aria-hidden="true">{line.glyph}</span>
                <span class="what">
                  <span>{line.text}</span>
                  {line.detail && <span class="quiet small">{line.detail}</span>}
                </span>
                {line.agentID && <button class="link" onClick={() => go({ host, project: folder, session: line.agentID })}>Open the agent →</button>}
              </li>
            ))}
          </ul>

          <h2 class="section-head">What it does</h2>
          <RuntimeRow store={store} host={host} summary={summary} disabled={locked} change={change} />
          <p class="agent-mode">
            <span>{agentModeWords(workflow.mode)}</span> <code class="quiet">agent: {workflow.mode}</code>
            {workflow.mode === "standing" && (standing
              ? <button class="link" onClick={() => go({ host, project: folder, session: standing.id })}>{standing.title ?? "Untitled"} →</button>
              : <span class="quiet"> · Started on the next run</span>)}
          </p>
          <pre class="prompt-text">{workflow.prompt || "(no prompt)"}</pre>
          <WorkflowSettingsForm store={store} host={host} summary={summary} disabled={locked} problem={problem.value?.workflowID === workflowID ? problem.value.text : null} change={change} />
          <p class="quiet small">{workflow.problem ? "Its settings can be changed here once its file can be read." : labelsNote(workflow)}</p>

          <h2 class="section-head">Triggers</h2>
          {workflow.triggers.length === 0 ? <p class="hint">None could be read from the file.</p> : (
            <ul class="triggers">
              {workflow.triggers.map((trigger, index) => {
                const filters = triggerFilters(trigger);
                const scope = scopeLine(trigger, projectName, hostName);
                return (
                  <li key={index} class="trigger">
                    <span class="glyph" aria-hidden="true">{triggerGlyph(trigger)}</span>
                    <span class="what">
                      <span>{triggerSummary(trigger, runtimeName)}
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

          <h2 class="section-head">Runs on</h2>
          <p class="quiet small">Every host with this project runs it, unless it is pinned to some of them. The file stores each computer's id, so renaming one does not unpin it.</p>
          <div class="host-pins">
            <label class="switch">
              <input type="checkbox" role="switch" aria-label="Every host" checked={pinned.length === 0} disabled={locked || pinned.length === 0}
                onChange={() => change({ hosts: [] })} />
              Every host
            </label>
            {rows.map((row) => (
              <label class="switch" key={row.machineID}>
                <input type="checkbox" aria-label={row.name} checked={pinned.includes(row.machineID)} disabled={locked}
                  onChange={(event) => {
                    const on = (event.currentTarget as HTMLInputElement).checked;
                    const next = on ? [...pinned, row.machineID] : pinned.filter((id) => id !== row.machineID);
                    change({ hosts: next });
                  }} />
                {row.name}
              </label>
            ))}
          </div>

          {unknown.length > 0 && (
            <>
              <h2 class="section-head">From a later version</h2>
              <div class="unknown-keys">
                <p class="quiet small">This version does not understand these lines in the file. They are kept as they are when the page changes it.</p>
                {unknown.map((line) => <code key={line}>{line}</code>)}
              </div>
            </>
          )}

          <h2 class="section-head">History</h2>
          <p class="last-ran quiet small">{lastRanLine(summary)}</p>

          {!loadingRuns.value && runs.value.length === 0 && <p class="hint">Nothing has run yet.</p>}
          {runs.value.map((agent) => (
            <SessionRow key={agent.id} agent={agent} chosen={false} onPick={() => go({ host, project: folder, session: agent.id })}
              waits={store.waitsOf(host, agent)} extras={rowExtras(store, host, agent)} />
          ))}
          {runs.value.length === runLimit.value && <button class="link" disabled={loadingRuns.value}
            onClick={() => { runLimit.value += 3; }}>Show more</button>}
        </div>
      </div>
    </section>
  );
}

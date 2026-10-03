// One workflow, opened in the chat's place (#98, #100, #142; the window's WorkflowPage and the
// Remote's), in their order: its name and what it is; Run Now or Approve, the Enabled switch and
// Archive or Bring Back; the status card, why it is or isn't running; what it does (who gets the
// prompt and, for a standing one, its agent; the prompt; its settings; its labels); what makes it
// run, a line a trigger, and its cooldown; what its file says that this version does not know; and
// the sessions it started. Every attribute is shown and none of the settings is edited here yet.
import type { Store } from "../model/store";
import { folderKey, projectFolder } from "../model/groups";
import {
  cooldownSentence, labelsNote, agentModeWords, settingRows, unknownLines, waitsItsTurn, workflowStatusLines, isOn, isSupportedTrigger, switchesSentence, lastRanLine, nextLine, resumedAgent, scopeLine, triggerFilters, triggerGlyph,
  triggerSummary, workflowSummary,
} from "../model/workflows";
import { go } from "../route";
import { RunNow } from "./WorkflowRow";
import { SessionRow } from "./SessionRow";
import { blockLines } from "../model/block";

export function WorkflowPage({ store, host, folder, projectName, workflowID, down }: {
  store: Store; host: string; folder: string; projectName: string; workflowID: string; down: boolean;
}) {
  const summary = (store.workflows.value[`${host}|${folderKey(folder)}`] ?? []).find((w) => w.workflow.workflowID === workflowID);
  const back = <button class="back narrow-only" onClick={() => go({ host, project: folder })}>‹ {projectName}</button>;
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
    ? (store.agents.value[host] ?? []).find((a) => a.id === summary.standingAgentID && a.archivedAt === undefined) : undefined;
  const cooldown = cooldownSentence(summary);
  const unknown = unknownLines(workflow);
  const runs = (store.agents.value[host] ?? [])
    .filter((a) => a.startedByWorkflow === workflowID && projectFolder(a) === folderKey(folder))
    .sort((a, b) => b.createdAt - a.createdAt);
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
          <p class="quiet small">.agents/workflows/{workflow.workflowID}.md</p>
          <p class="agent-mode">
            <span>{agentModeWords(workflow.mode)}</span> <code class="quiet">agent: {workflow.mode}</code>
            {workflow.mode === "standing" && (standing
              ? <button class="link" onClick={() => go({ host, project: folder, session: standing.id })}>{standing.title ?? "Untitled"} →</button>
              : <span class="quiet"> · Started on the next run</span>)}
          </p>
          <pre class="prompt-text">{workflow.prompt || "(no prompt)"}</pre>
          {workflow.mode === "triggering" && <p class="quiet small">This workflow resumes the agent that triggered it, so these do not apply.</p>}
          {workflow.mode === "standing" && <p class="quiet small">Applied when its standing agent is started, and again if it has to be replaced.</p>}
          <dl class="settings">
            {settingRows(workflow, runtimeName).map(([name, value]) => (
              <div key={name}><dt>{name}</dt><dd>{value}</dd></div>
            ))}
          </dl>
          <div class="labels" role="group" aria-label="Labels">
            {workflow.settings.labels.map((label) => <span key={label} class="chip label">{label}</span>)}
          </div>
          <p class="quiet small">{labelsNote(workflow)} Its settings and labels are changed in the window or on the Remote.</p>

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
          {cooldown && <p class="quiet small">{cooldown}</p>}

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

          {runs.length === 0 && <p class="hint">Nothing has run yet.</p>}
          {runs.slice(0, 6).map((agent) => (
            <SessionRow key={agent.id} agent={agent} chosen={false} onPick={() => go({ host, project: folder, session: agent.id })}
              waits={blockLines(agent, store.agents.value[host] ?? [])} />
          ))}
        </div>
      </div>
    </section>
  );
}

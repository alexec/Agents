// One workflow, opened in the chat's place (#98, #100; the window's WorkflowPage and the
// Remote's): its name, what it is and what is happening to it; Run Now and the Enabled switch;
// what makes it run, a line a trigger, with its filters, whose events it listens to and, for a
// schedule, when it is next due; when it last ran and on what; the prompt as it will be sent; and
// the sessions it started. Read-only otherwise: its settings and approving it are the window's.
import type { Store } from "../model/store";
import { folderKey, projectFolder } from "../model/groups";
import {
  happening, isOn, isSupportedTrigger, switchesSentence, lastRanLine, nextLine, resumedAgent, scopeLine, triggerFilters, triggerGlyph,
  triggerSummary, workflowSummary, workflowNeedsAPerson,
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
  const said = happening(summary);
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
            {workflow.problem && <p class={workflowNeedsAPerson(summary) ? "failure" : "quiet"}>{workflowSummary(workflow, runtimeName)}</p>}
            {said && <p class={`happening${workflowNeedsAPerson(summary) ? " tinted" : " quiet"}`}>{said}</p>}
          </div>
          {!summary.isArchived && !summary.awaitingApproval && (
            <div class="controls">
              <RunNow store={store} host={host} summary={summary} disabled={down} wide />
              {/* Beside Run Now, which still works with it off (#100). */}
              <label class="switch" title={isOn(summary) ? "On: its triggers run it" : "Off: none of its triggers run it; Run Now still does"}>
                <input type="checkbox" role="switch" aria-label="Enabled" checked={isOn(summary)} disabled={down}
                  onChange={(e) => void store.setWorkflowEnabled(host, summary, (e.currentTarget as HTMLInputElement).checked)} />
                Enabled
              </label>
              {/* The switch writes the workflow's file (#125), the window's words. */}
              <p class="quiet small">{switchesSentence(summary)}</p>
            </div>
          )}

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
          <p class="last-ran quiet small">{lastRanLine(summary)}</p>

          <h2 class="section-head">Prompt</h2>
          <p class="quiet small">.agents/workflows/{workflow.workflowID}.md</p>
          <pre class="prompt-text">{workflow.prompt || "(no prompt)"}</pre>

          <h2 class="section-head">Recent runs</h2>
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

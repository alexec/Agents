// Deployed on a release's page and Live in on a pull request's (#5243, spec 5239-deploy-model boards 1 to 3): a
// row for each environment, its tier chip when it is production and the state's chip, then what went out (the
// component and its version: the panel is a 240 px column, so the component is under the name, as board 2 draws a
// phone's row) and since when. A waiting deploy's row has Approve and Reject when the person is one of its gate's
// reviewers (note 9): the same approval as Needs You (#3587). A failed row opens the job's log (note 10).
import { useSignal } from "@preact/signals";
import type { Approval } from "../protocol/generated";
import type { Store } from "../model/store";
import { type DeployRow, deployStateWords } from "../model/deployRows";
import { describe } from "../model/errors";

/** The waiting deploy's approval in a folder's list on any machine: its key is the gate's `owner/name/<run id>`. */
function gateApproval(store: Store, gate: string): { host: string; folder: string; approval: Approval } | undefined {
  const want = gate.toLowerCase();
  for (const [host, summaries] of Object.entries(store.folders.value)) {
    for (const summary of summaries ?? []) {
      const approval = summary.approvals?.find((a) => a.kind === "deploy" && a.key.toLowerCase() === want);
      if (approval) return { host, folder: summary.folder.folder, approval };
    }
  }
  return undefined;
}

export function DeployRows({ store, rows }: { store: Store; rows: readonly DeployRow[] }) {
  return <ul class="work-deploys">{rows.map((r) => <DeployRowView key={`${r.environment} ${r.node.ref}`} store={store} row={r} />)}</ul>;
}

function DeployRowView({ store, row }: { store: Store; row: DeployRow }) {
  const problem = useSignal<string | null>(null);
  const gate = row.state === "waiting" && row.gate ? gateApproval(store, row.gate) : undefined;
  const answer = (approve: boolean) => {
    if (!gate) return;
    problem.value = null;
    store.answerApproval(gate.host, gate.folder, gate.approval, approve ? "approve" : "deny", gate.approval.digest)
      .catch((e: unknown) => { problem.value = describe(e); });
  };
  return (
    <li class="work-deploy">
      <div class="work-deploy-head">
        <span class="work-deploy-env">{row.environment}</span>
        {row.tier && <span class="work-deploy-tier">{row.tier}</span>}
        <span class={`work-deploy-state ${row.state}`}>{deployStateWords[row.state]}</span>
      </div>
      <span class="small work-deploy-line">{row.line}</span>
      {row.more && (row.state === "failed" && row.url
        ? <a class="small work-deploy-more" href={row.url} target="_blank" rel="noopener noreferrer">{row.more}</a>
        : <span class="small quiet work-deploy-more">{row.more}</span>)}
      {gate && (
        <span class="work-deploy-gate">
          <button type="button" class="primary" onClick={() => answer(true)}>Approve</button>
          <button type="button" onClick={() => answer(false)}>Reject</button>
        </span>
      )}
      {problem.value && <span class="small work-deploy-problem">{problem.value}</span>}
    </li>
  );
}

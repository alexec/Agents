// Settings ▸ Control plane ▸ Move (#4255), as the window's Overview card (frames O, T, Y): Move to Another
// Machine…, the forwarding rows with Stop Forwarding…, and Run It Here Again…, and the sheet each opens (frames
// P–S, V–X). The window on the Mac does every step with that Mac's control key (control/planeMove) and says how it
// stands; this page draws what it says. Listed in ./sections.ts.
import { useState } from "preact/hooks";
import type { PlaneMoveAction, PlaneMoveFlow, PlaneMoveRow } from "../../protocol/generated";
import { describe } from "../../model/errors";
import { flowButtons, isBad, keepsOpen, lineMark, memberState, planeMoveWords as words, showsNote, stepTitle } from "../../model/planeMove";
import type { Store } from "../../model/store";
import { Modal } from "../Modal";

export function PlaneMoveSection({ store, down }: { store: Store; down: boolean }) {
  const report = store.planeMoveReport.value;
  const [problem, setProblem] = useState<string | null>(null);
  const ask = (action: PlaneMoveAction, address?: string) => {
    setProblem(null);
    store.askPlaneMove(address === undefined ? { action } : { action, address }).catch((error) => setProblem(describe(error)));
  };
  const press = (row: PlaneMoveRow) => {
    if (!row.action) return;
    if (row.confirm && !window.confirm(`${words.confirmTitle}\n\n${row.confirm}`)) return;
    ask(row.action);
  };
  if (!report) return null;
  return (
    <section aria-labelledby="settings-plane-move">
      <h3 class="section-head" id="settings-plane-move">{words.head}</h3>
      {report.rows.map((row) => (
        <div class="setting plane-move-row" key={row.kind}>
          <span>
            {row.attention && <span class="dot attention" aria-hidden="true" />}
            {row.title}
            {row.detail && <span class="hint"> · {row.detail}</span>}
          </span>
          {row.button && (
            <button type="button" disabled={down || !!row.disabled || !!report.flow} onClick={() => press(row)}>{row.button}</button>
          )}
        </div>
      ))}
      <p class="hint">On {report.mac}.</p>
      {(problem ?? report.problem) && <p class="hint failure" role="alert">{problem ?? report.problem}</p>}
      {report.flow && <PlaneMoveDialog flow={report.flow} down={down} ask={ask} />}
    </section>
  );
}

function PlaneMoveDialog({ flow, down, ask }: { flow: PlaneMoveFlow; down: boolean; ask: (action: PlaneMoveAction, address?: string) => void }) {
  const [typed, setTyped] = useState(flow.address ?? "");
  const buttons = flowButtons(flow);
  const step = stepTitle(flow);
  const check = () => { if (typed.trim()) ask("check", typed.trim()); };
  return (
    <Modal label={flow.title} close={() => ask(flow.failed ? "close" : "cancel")} keep={() => keepsOpen(flow)}>
      <form class="sheet-body plane-move-sheet" onSubmit={(e) => {
        e.preventDefault();
        const main = buttons.find((b) => b.prominent && !b.disabled);
        if (main) ask(main.action);
      }}>
        <h2>{flow.title}</h2>
        {flow.lead && <p class="sheet-note">{flow.lead}</p>}
        {step && <p class="step-title">{step}</p>}
        {flow.kind === "move" && flow.step === "key" && (
          <ol class="plane-move-steps">
            <li>
              <p>{words.keySave}</p>
              <button type="button" disabled={down} onClick={() => ask("saveKey")}>{words.saveKey}</button>
              <span class="hint"> {words.saveKeyNote}</span>
              <pre class="command">{words.sealCommand}</pre>
              <p class="hint">{words.gcp}</p>
            </li>
            <li>
              <p>{words.startThere}</p>
              <pre class="command">{words.startCommand}</pre>
              <p class="hint">{words.startNote}</p>
            </li>
          </ol>
        )}
        {flow.kind === "move" && flow.step === "check" && (
          <div class="plane-move-address">
            <input type="url" aria-label="Address" placeholder="agents.example.com" spellcheck={false} autocomplete="off"
              value={typed} onInput={(e) => setTyped(e.currentTarget.value)} autoFocus
              onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); check(); } }} />
            <button type="button" disabled={down || !typed.trim() || !!flow.busy} onClick={check}>Check</button>
          </div>
        )}
        {flow.kind === "return" && flow.step === "check" && flow.otherKey && (
          <ol class="plane-move-steps">
            <li><p>{words.exportKey}</p><pre class="command">{words.exportCommand}</pre></li>
            <li>
              <p>{words.useKeyNote}</p>
              <button type="button" disabled={down || !!flow.busy} onClick={() => ask("useKey")}>{words.useKey}</button>
            </li>
          </ol>
        )}
        {flow.lines && flow.lines.length > 0 && (
          <ul class="plane-move-lines">
            {flow.lines.map((line) => (
              <li key={line.label} class={`line-${isBad(line) ? "bad" : line.state}`}>
                <span class="mark" aria-hidden="true">{lineMark(line)}</span>
                <span>
                  {line.label}
                  {showsNote(line) && <span class="hint">{line.note}</span>}
                </span>
              </li>
            ))}
          </ul>
        )}
        {flow.step === "told" && (flow.members ? (
          <ul class="plane-move-members">
            {flow.members.map((member) => (
              <li key={member.name} class={`member-${member.state}`}>
                <span>{member.name}<span class="hint">{member.kind}</span></span>
                <span>{memberState(member)}{member.note && <span class="hint">{member.note}</span>}</span>
              </li>
            ))}
          </ul>
        ) : <p class="sheet-note" role="status">{words.asking}</p>)}
        {flow.knowing && <p class="sheet-note">{flow.knowing}</p>}
        {flow.problem && <p class="sheet-note failure" role="alert">{flow.problem}</p>}
        <div class="sheet-actions">
          {buttons.filter((b) => b.left).map((b) => (
            <button key={b.label} type="button" class="leading" disabled={down || !!b.disabled} onClick={() => ask(b.action)}>{b.label}</button>
          ))}
          {buttons.filter((b) => !b.left).map((b) => (
            <button key={b.label} type={b.prominent ? "submit" : "button"} class={b.prominent ? "prominent" : undefined}
              disabled={down || !!b.disabled} onClick={b.prominent ? undefined : () => ask(b.action)}>{b.label}</button>
          ))}
        </div>
      </form>
    </Modal>
  );
}

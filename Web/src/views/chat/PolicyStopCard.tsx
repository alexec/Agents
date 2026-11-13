// The Stopped by a policy card (#2957, FR-025, frame E): the rule, the layer that decides and its value, the machine's
// words, and one answer: Change for a layer the person can edit (yours, or a folder's), Open Spending for an
// organisation budget, See Organisation Policy for another organisation rule. At the organisation's budget, Ask for
// More asks an admin to raise it for today (#3262), as an Ask at the end of the chat (#5031), and the card then says where the request stands. The window's is
// Shared/UI/Chat/PolicyStopCard.swift.
import { signal, useSignal } from "@preact/signals";
import type { BudgetRequest, PolicyRefusal } from "../../protocol/generated";
import { askedWords, askForMoreHelp, askForMoreTitle, askRefusal, canAskForMore, organisationItem, policyItem, stopAction, stoppedTitle,
  stopLayerLine, stopRuleTitle, type StopAction } from "../../model/policyLayers";
import { failedWords } from "../../model/console";
import { go, usageAsked } from "../../route";
import { Ask } from "../Ask";

function open(action: StopAction): void {
  switch (action.kind) {
    case "yours":
      go({ nav: "settings", section: "settings", item: policyItem() });
      break;
    case "folder":
      go({ nav: "settings", section: "settings", item: policyItem(action.folder) });
      break;
    case "spending":
      // Usage's Cost pane, the web page's Spending.
      usageAsked.value = "spending";
      go({ nav: "reports", section: "usage" });
      break;
    case "organisation":
      go({ nav: "settings", section: "settings", item: organisationItem });
      break;
  }
}

/** Ask for More's answer, by the policy stop's entry: the record and its Ask say the same (#5031). */
const askedFor = signal<Record<string, BudgetRequest>>({});

/**
 * A policy stop on the record: the rule, the layer, the words and where to change it. Ask for More
 * is an Ask at the end of the chat while it can be raised (PolicyStopAsk); this line then says where
 * the request stands.
 */
export function PolicyStopCard({ refusal, entryID }: { refusal: PolicyRefusal; entryID: string }) {
  const rule = stopRuleTitle(refusal.rule);
  const layer = stopLayerLine(refusal);
  const action = stopAction(refusal);
  const asked = askedFor.value[entryID];
  return (
    <div class="note policy-stop">
      <p class="strong">{stoppedTitle}</p>
      {rule && <p>{rule}</p>}
      {layer && <p class="quiet">{layer}</p>}
      <p>{refusal.words}</p>
      {asked && <p class="quiet small">{askedWords(asked)}</p>}
      <p class="answers"><button class="link" onClick={() => open(action)}>{action.label}</button></p>
    </div>
  );
}

/** Whether the stop at `entryID` can still be raised by Ask for More from here. */
export function canRaise(refusal: PolicyRefusal, entryID: string, send: unknown): boolean {
  return !!send && !askedFor.value[entryID] && canAskForMore(refusal);
}

/** A policy stop that can be raised (#3262), as an Ask (#5031): Ask for More, or where to change it. */
export function PolicyStopAsk({ refusal, entryID, send }: { refusal: PolicyRefusal; entryID: string; send: () => Promise<BudgetRequest> }) {
  const rule = stopRuleTitle(refusal.rule);
  const action = stopAction(refusal);
  const asking = useSignal(false);
  const problem = useSignal<string | null>(null);
  const ask = async () => {
    asking.value = true;
    try {
      askedFor.value = { ...askedFor.value, [entryID]: await send() };
      problem.value = null;
    } catch (error) {
      problem.value = askRefusal(error) ?? failedWords(error);
    } finally {
      asking.value = false;
    }
  };
  return (
    <Ask glyph="ban" title={stoppedTitle} label={stoppedTitle} alert extra="policy-ask"
      decline={<button class="link" onClick={() => open(action)}>{action.label}</button>}
      buttons={<button class="prominent" title={askForMoreHelp} disabled={asking.value} data-default="" onClick={() => void ask()}>{askForMoreTitle}</button>}>
      {rule && <p>{rule}</p>}
      <p class="quiet small">{refusal.words}</p>
      {problem.value && <p class="failure small" role="alert">{problem.value}</p>}
    </Ask>
  );
}

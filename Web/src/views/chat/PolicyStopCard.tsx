// The Stopped by a policy card (#2957, FR-025, frame E): the rule, the layer that decides and its value, the machine's
// words, and one answer: Change for a layer the person can edit (yours, or a folder's), Open Spending for an
// organisation budget, See Organisation Policy for another organisation rule. At the organisation's budget, Ask for
// More asks an admin to raise it for today (#3262), and the card then says where the request stands. The window's is
// Shared/UI/Chat/PolicyStopCard.swift.
import { useContext } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { BudgetRequest, PolicyRefusal } from "../../protocol/generated";
import { askedWords, askForMoreHelp, askForMoreTitle, askRefusal, canAskForMore, organisationItem, policyItem, stopAction, stoppedTitle,
  stopLayerLine, stopRuleTitle, type StopAction } from "../../model/policyLayers";
import { failedWords } from "../../model/console";
import { go, usageAsked } from "../../route";
import { CallActionsContext } from "./Rows";

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

export function PolicyStopCard({ refusal }: { refusal: PolicyRefusal }) {
  const rule = stopRuleTitle(refusal.rule);
  const layer = stopLayerLine(refusal);
  const action = stopAction(refusal);
  const send = useContext(CallActionsContext)?.askForMore;
  const asked = useSignal<BudgetRequest | null>(null);
  const asking = useSignal(false);
  const problem = useSignal<string | null>(null);
  const ask = async (sendAsk: () => Promise<BudgetRequest>) => {
    asking.value = true;
    try {
      asked.value = await sendAsk();
      problem.value = null;
    } catch (error) {
      problem.value = askRefusal(error) ?? failedWords(error);
    } finally {
      asking.value = false;
    }
  };
  const offer = send && !asked.value && canAskForMore(refusal) ? send : undefined;
  return (
    <div class="note policy-stop">
      <p class="strong">{stoppedTitle}</p>
      {rule && <p>{rule}</p>}
      {layer && <p class="quiet">{layer}</p>}
      <p>{refusal.words}</p>
      {asked.value && <p class="quiet small">{askedWords(asked.value)}</p>}
      {problem.value && <p class="failure small" role="alert">{problem.value}</p>}
      <p class="answers">
        {offer && <button title={askForMoreHelp} disabled={asking.value} onClick={() => void ask(offer)}>{askForMoreTitle}</button>}
        <button onClick={() => open(action)}>{action.label}</button>
      </p>
    </div>
  );
}

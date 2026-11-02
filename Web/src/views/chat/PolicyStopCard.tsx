// The Stopped by a policy card (#2957, FR-025, frame E): the rule, the layer that decides and its value, the machine's
// words, and one answer: Change for a layer the person can edit (yours, or a folder's), Open Spending for an
// organisation budget, See Organisation Policy for another organisation rule. The window's is
// Shared/UI/Chat/PolicyStopCard.swift.
import type { PolicyRefusal } from "../../protocol/generated";
import { organisationItem, policyItem, stopAction, stoppedTitle, stopLayerLine, stopRuleTitle, type StopAction } from "../../model/policyLayers";
import { go, usageAsked } from "../../route";

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
  return (
    <div class="note policy-stop">
      <p class="strong">{stoppedTitle}</p>
      {rule && <p>{rule}</p>}
      {layer && <p class="quiet">{layer}</p>}
      <p>{refusal.words}</p>
      <p class="answers"><button onClick={() => open(action)}>{action.label}</button></p>
    </div>
  );
}

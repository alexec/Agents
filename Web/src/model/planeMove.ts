// Move to Another Machine… and Run It Here Again… on the page (#4255), as the window's sheets
// (`Host/Sources/MachineMove.swift`, `Host/Sources/MachineReturn.swift`, frames O–Y). The window on the
// Mac does each step with that Mac's control key, which never leaves it, and says how it stands
// (control/planeMoveReported) in its own words: the page adds only what never changes.
import type { PlaneMoveFlow, PlaneMoveLine, PlaneMoveMember } from "../protocol/generated";

export const planeMoveWords = {
  head: "Move",
  // Frame P: the key, sealed in the other machine's store over ssh, and that machine started empty.
  keyStep: "1 · Give the other machine this control plane's key",
  keySave: "Save the key. Before the control plane there first starts, seal the key in its store. The key goes in over ssh, so it's never written on that machine:",
  saveKey: "Save Key…",
  saveKeyNote: "Agent Loops on the Mac asks where to save it.",
  sealCommand: `ssh you@agents.example.com 'cd agents && docker compose \\
  -f deploy/compose.public.yaml build control'
ssh you@agents.example.com 'cd agents && docker compose \\
  -f deploy/compose.public.yaml \\
  run --rm -T control key seal --key-fd 0' < control-key`,
  gcp: "On Google Cloud, deploy/gcp/up.sh --seal-key control-key does this. Anyone who has the key can pose as your control plane: delete the saved copy on the Mac once it's sealed.",
  startThere: "Start the control plane there, empty, waiting for this one:",
  startCommand: `AGENTS_CONTROL_RECEIVE=1 docker compose \\
  -f deploy/compose.public.yaml up -d`,
  startNote: "See Run the control plane in the cloud.",
  whereStep: "2 · Where is it?",
  tellStep: "3 · Tell everyone where it's going",
  checkStep: "1 · Check both ends",
  tellBackStep: "2 · Tell everyone where it's going",
  // Frame V: the other machine made its own key, so the Mac takes it first (#1477).
  exportKey: "Write its key to a file on the Mac. It comes out over ssh, so it's never written on that machine:",
  exportCommand: `(umask 077; ssh you@agents.example.com 'cd agents && \\
  docker compose -f deploy/compose.public.yaml \\
  run --rm -T control key export --key-fd 1' > control-key)`,
  useKeyNote: "Give it to the Mac, then delete the file. The Mac keeps its own key aside.",
  useKey: "Use Key…",
  asking: "Asking Agent Loops on the Mac…",
  confirmTitle: "Stop forwarding?",
} as const;

/** The step's small title above its body, as the sheet's. */
export function stepTitle(flow: PlaneMoveFlow): string | null {
  const w = planeMoveWords;
  if (flow.kind === "move") {
    return flow.step === "key" ? w.keyStep : flow.step === "check" ? w.whereStep : flow.step === "told" ? w.tellStep : null;
  }
  return flow.step === "check" ? w.checkStep : flow.step === "told" ? w.tellBackStep : null;
}

/** The mark before a check or a stage, as the sheet's symbols. */
export function lineMark(line: PlaneMoveLine): string {
  switch (line.state) {
    case "yes": case "done": return "✓";
    case "no": case "failed": return "✗";
    case "doing": return "…";
    case "todo": return "○";
    case "warning": return "!";
    default: return "–";
  }
}

/** A check's note shows when it failed, or as a hint once it passed, as the sheet's tick; a stage's always. */
export const showsNote = (line: PlaneMoveLine) => !!line.note && line.state !== "waiting";

/** Whether a line is shown as a problem. */
export const isBad = (line: PlaneMoveLine) => line.state === "no" || line.state === "failed";

/** A member's state, in the sheet's words. */
export function memberState(member: PlaneMoveMember): string {
  return member.state === "knows" ? "✓ Knows" : member.state === "cantFollow" ? "Can't follow" : "Not yet";
}

export type FlowButton = { label: string; action: "cancel" | "close" | "continue" | "back" | "check" | "announce" | "withdraw" | "moveNow"; prominent?: boolean; disabled?: boolean; left?: boolean };

/** The sheet's buttons for where it is, in its order: the left one first, then the right ones. */
export function flowButtons(flow: PlaneMoveFlow): FlowButton[] {
  const busy = !!flow.busy;
  switch (flow.step) {
    case "key":
      return [{ label: "Cancel", action: "cancel" }, { label: "Continue", action: "continue", prominent: true }];
    case "check": {
      const left: FlowButton[] = flow.kind === "move"
        ? [{ label: "Back", action: "back", left: true }]
        : flow.checked ? [] : [{ label: "Check Again", action: "check", left: true, disabled: busy }];
      return [...left, { label: "Cancel", action: "cancel" },
        { label: "Tell Everyone", action: "announce", prominent: true, disabled: !flow.checked || busy }];
    }
    case "told":
      return [{ label: "Withdraw", action: "withdraw", left: true }, { label: "Cancel", action: "cancel" },
        { label: "Move Now", action: "moveNow", prominent: true }];
    case "moving":
      return flow.failed ? [{ label: "Close", action: "close" }] : [{ label: "Cancel", action: "cancel", disabled: !!flow.taken }];
  }
}

/** Escape leaves the sheet open while a step runs or once the other end serves, as the sheet's Cancel. */
export const keepsOpen = (flow: PlaneMoveFlow) => !!flow.busy || (flow.step === "moving" && !flow.failed);

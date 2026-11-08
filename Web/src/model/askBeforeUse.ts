// Ask before use (#4014, #4016), on the Secrets page, For One Session and the ask_secret card. On,
// only the machine's host uses the value: to fill a page, to set a CI secret or to call an HTTP MCP
// server. Off, every session on the machine can read it. The words are AskBeforeUseWords' in
// Packages/AgentsKit/Sources/AgentsKitCore/Model/AskBeforeUse.swift.

export const askBeforeUseWords = {
  toggle: "Ask before use",
  asks: "Asks before use",
  on: "Only fill_secret, set_ci_secret and HTTP MCP servers can use it. It is not in $NAME or in a file.",
  off: "Every session on the machine can read it, as $NAME and from a file.",
} as const;

/** The answer's choice on the ask_secret card, as the host names it: left out is on. */
export const needsApprovalField = "needsApproval";

/** Under the toggle. */
export function askBeforeUseHint(on: boolean): string {
  return on ? askBeforeUseWords.on : askBeforeUseWords.off;
}

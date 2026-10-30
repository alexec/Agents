// What the host says on a folder's pull request when it merges (#2352), as the window's
// PRCostComment (Packages/AgentsKit/Sources/AgentsKitCore/Model/PRCostComment.swift) says it.
import type { PRCostComment } from "../protocol/generated";

export const prCostCommentChoices: PRCostComment[] = ["off", "tokens", "cost"];

export const prCostCommentWords: Record<PRCostComment, string> = {
  off: "Off",
  tokens: "Tokens and time",
  cost: "Cost, tokens and time",
};

export const prCostCommentTitle = "Cost on Pull Requests";

export const prCostCommentHelp = "When a pull request of this folder's repository merges, "
  + "Agents comments on it with what its work cost, and edits that comment when more comes in. "
  + "A public repository's comment is public.";

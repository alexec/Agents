/** NeedID (Attention/Need.swift): what is being answered, one key per kind. */
export type NeedID =
  | { permission: UUID }
  | { elicitation: UUID }
  | { report: { agentID: UUID; at: WireDate } };

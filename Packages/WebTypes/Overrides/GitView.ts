// uses: ChangesUnavailable
/** GitView (Model/AgentChanges.swift): `{ shared: { since } }`, `{ unavailable: … }` and so on. */
export type GitView =
  | { owned: { since: string } }
  | { shared: { since: string } }
  | { sharedFromHead: Record<string, never> }
  | { unavailable: ChangesUnavailable };

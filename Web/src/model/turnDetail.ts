/** How much of a turn is drawn (TurnDetail). */
export type TurnDetail = "outcome" | "messages" | "steps" | "details";
export const turnDetails: readonly TurnDetail[] = ["outcome", "messages", "steps", "details"];

/** The level before anyone has chosen one, on every client (#993). */
export const initialDetail: TurnDetail = "messages";

/** The level kept in storage, or the initial one when nothing (or nothing known) is kept. */
export function savedDetail(saved: string | null): TurnDetail {
  return turnDetails.find((d) => d === saved) ?? initialDetail;
}

/**
 * A turn opened or closed by its *N steps*, from `now` with the app at `level`. Open is the
 * level when it shows steps and Messages when it does not (#759); closed is always the outcome.
 */
export function toggled(now: TurnDetail, level: TurnDetail): TurnDetail {
  return now !== "outcome" ? "outcome" : level !== "outcome" ? level : "messages";
}

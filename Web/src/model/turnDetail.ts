/** The levels every turn can start at (TurnDetail.levels, #1286). */
export type TurnLevel = "messages" | "steps" | "details";
/** How much of a turn is drawn (TurnDetail): a level, or one turn closed by its *N steps*. */
export type TurnDetail = TurnLevel | "collapsed";
export const turnDetails: readonly TurnLevel[] = ["messages", "steps", "details"];

/** The level before anyone has chosen one, on every client (#993). */
export const initialDetail: TurnLevel = "messages";

/**
 * The level kept in storage, or the initial one when nothing (or nothing known) is kept. An
 * `outcome` kept from when it was a level reads as the initial one (#1286).
 */
export function savedDetail(saved: string | null): TurnLevel {
  return turnDetails.find((d) => d === saved) ?? initialDetail;
}

/**
 * A turn opened or closed by its *N steps*, from `now` with the app at `level`. Open is the
 * level; closed is always collapsed.
 */
export function toggled(now: TurnDetail, level: TurnLevel): TurnDetail {
  return now !== "collapsed" ? "collapsed" : level;
}

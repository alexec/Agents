/**
 * Whether a turn is drawn with its steps (TurnDetail): every turn opens with them, and its
 * *N steps* closes one. There are no levels (#1315): a run, a call and a thought each open in
 * their place.
 */
export type TurnDetail = "open" | "collapsed";

/** Every turn before anyone opens or closes it, on every client (#993). */
export const initialDetail: TurnDetail = "open";

/** The turn opened or closed by its *N steps*. */
export function toggled(now: TurnDetail): TurnDetail {
  return now === "open" ? "collapsed" : "open";
}

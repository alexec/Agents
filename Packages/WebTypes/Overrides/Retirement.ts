// uses: Hold
/** Retirement (Model/Retirement.swift): one key, or none for a kind this build can't name. */
export type Retirement =
  | { at: WireDate }
  | { nextUnderCap: Record<string, never> }
  | { held: Hold }
  | Record<string, never>;

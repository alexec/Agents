// Dates on the wire are seconds since 2001-01-01T00:00:00Z: Swift's Date through a plain
// JSONEncoder (contracts/generated-types.md, T017). Not 1970.
import type { WireDate } from "./generated";

/** 2001-01-01T00:00:00Z in milliseconds since 1970. */
const referenceDate = Date.UTC(2001, 0, 1);

export function fromWireDate(seconds: WireDate): Date {
  return new Date(referenceDate + seconds * 1000);
}

export function toWireDate(date: Date): WireDate {
  return ((date.getTime() - referenceDate) / 1000) as WireDate;
}

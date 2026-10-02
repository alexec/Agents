/**
 * EventPattern (Model/EventPattern.swift), as its encode(to:) writes it (073): `filters` holds
 * every filter as one string, a list joined by `|` so an older build reads it as a value that
 * never matches, and `anyOf` holds the lists whole. Read `anyOf` over `filters`.
 */
export interface EventPattern {
  name: string;
  filters: Record<string, string>;
  anyOf?: Record<string, string[]>;
}

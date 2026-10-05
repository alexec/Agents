// A question's string field as its format asks (#265): the Remote's DatePicker and keyboards
// (Elicitation/FormPages.swift), as the browser's own inputs. A date is sent as yyyy-MM-dd and a
// date-time as ISO 8601 in UTC, as the Remote's formatters write them.
import type { ElicitationSchemaPropertyFormat } from "../protocol/generated";

export function inputType(format: ElicitationSchemaPropertyFormat | undefined): "text" | "date" | "datetime-local" | "email" | "url" {
  switch (format) {
    case "date": return "date";
    case "date-time": return "datetime-local";
    case "email": return "email";
    case "uri": return "url";
    default: return "text";
  }
}

/** FormPages.placeholder. */
export function placeholder(format: ElicitationSchemaPropertyFormat | undefined): string {
  return format === "email" ? "name@example.com" : format === "uri" ? "https://" : "";
}

/** What a datetime-local input holds (local time, to the minute) as the answer: ISO 8601, UTC. */
export function momentFromInput(local: string): string {
  const date = new Date(local);
  return Number.isNaN(date.getTime()) ? local : date.toISOString().replace(/\.\d{3}Z$/, "Z");
}

/** An answer as a datetime-local input shows it, in local time. */
export function momentToInput(answer: string): string {
  const date = new Date(answer);
  if (Number.isNaN(date.getTime())) return "";
  const two = (n: number) => String(n).padStart(2, "0");
  return `${date.getFullYear()}-${two(date.getMonth() + 1)}-${two(date.getDate())}T${two(date.getHours())}:${two(date.getMinutes())}`;
}

import { stringify } from "yaml";
import type { JSONValue } from "../protocol/generated";

/**
 * A tool's argument or return as it reads (#3569): text as it came, anything with a shape as
 * YAML, keys sorted, as the window's TranscriptRows draws it. A list of bytes, the way some
 * runtimes send a tool's output, is read as text.
 */
export function readable(value: JSONValue): { text: string; structured: boolean } {
  if (Array.isArray(value) && value.length && value.every((v) => typeof v === "number" && v >= 0 && v <= 255 && Number.isInteger(v))) {
    try {
      return { text: new TextDecoder("utf-8", { fatal: true }).decode(new Uint8Array(value as number[])), structured: false };
    } catch { /* not text: drawn as it came */ }
  }
  if (typeof value === "string") return { text: value, structured: false };
  // As Yams writes it: a long line scrolls in its box rather than folding, a list sits under its key.
  return { text: stringify(value, { sortMapEntries: true, lineWidth: 0, indentSeq: false }).replace(/\n$/, ""), structured: true };
}

// The words for an epic's forecast (#4527) on Work's epic page, from lineage/forecast (#4526), as ForecastWords has
// them on the window: when it lands (P50, and P85 as the "85%"), what it costs to complete, and, for a closed epic,
// the first forecast against when it landed. The method is in specs/4533-forecasting/spec.md.
import { fromWireDate } from "../protocol/dates";
import type { LineageEstimateRange, LineageForecast, WireDate } from "../protocol/generated";
import { rough } from "./estimate";

/** The reasons that say nothing to a person on an epic's page: the page shows no line for them. */
const silent = new Set(["not an epic", "no open children"]);

const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;
const percent = (v: number) => `${Math.round(v * 1000) / 10}%`;
const ratio = (v: number) => String(Math.round(v * 100) / 100);
const twoDays = 48 * 3600 * 1000;
const ms = (d: WireDate) => fromWireDate(d).getTime();

/** "Thu 12 Nov", or "Thu 12 Nov, 15:00" when the forecast is for the next two days. */
export function day(d: WireDate, hours: boolean, locale?: string, timeZone?: string): string {
  const at = fromWireDate(d);
  const date = new Intl.DateTimeFormat(locale, { weekday: "short", day: "numeric", month: "short", timeZone }).format(at);
  return hours ? `${date}, ${new Intl.DateTimeFormat(locale, { hour: "2-digit", minute: "2-digit", timeZone }).format(at)}` : date;
}

/** "about $60 to $140", or "about $60" when both ends round the same. */
function span(r: LineageEstimateRange, currency: string, about = true): string {
  const low = rough(r.p10, currency), high = rough(r.p90, currency);
  const words = low === high ? rough(r.median, currency) : `${low} to ${high}`;
  return about ? `about ${words}` : words;
}

/** "Likely lands by Thu 12 Nov (85%: by Fri 13 Nov), at the last 14 days' pace"; with no date, "No landing forecast:
 * fewer than 5 closed epics"; undefined when there is nothing to say. */
export function landsLine(f: LineageForecast, locale?: string, timeZone?: string): string | undefined {
  const l = f.lands;
  if (!l) return f.noForecast && !silent.has(f.noForecast) ? `No landing forecast: ${f.noForecast}` : undefined;
  const hours = ms(l.p85) - ms(f.at) < twoDays;
  return `Likely lands by ${day(l.p50, hours, locale, timeZone)} (85%: by ${day(l.p85, hours, locale, timeZone)}), `
    + `at the last ${f.windowDays} days' pace`;
}

/** "To complete: about $60 to $140 ($80 to $190 all in)", with no "all in" when it rounds the same; undefined until 3
 * closed children have an estimate and an actual. */
export function toCompleteLine(f: LineageForecast): string | undefined {
  const t = f.toComplete;
  const priced = Object.entries(t?.cost ?? {}).sort(([a], [b]) => a.localeCompare(b));
  if (!t || priced.length === 0) return undefined;
  const parts = priced.map(([code, r]) => {
    const all = t.loaded?.[code], words = span(r, code);
    return all && span(all, code) !== words ? `${words} (${span(all, code, false)} all in)` : words;
  });
  return `To complete: ${parts.join("; ")}`;
}

/** The assumptions, for the lines' help: what the dates count and what they leave out, and what the estimate to
 * complete is made from. */
export function forecastHelp(f: LineageForecast): string | undefined {
  const words: string[] = [];
  const l = f.lands;
  if (l) {
    let w = `For the ${plural(l.open, "open child", "open children")} filed now, not ones still to come: `
      + `1,000 draws of the last ${f.windowDays} days' landings, hour by hour, of which an epic gets `
      + `${percent(l.share)}, the median of ${plural(l.groups, "closed epic", "closed epics")}.`;
    if (l.stepsLeft > 1) w += ` The ${l.stepsLeft} blocked-by steps left do not move the date.`;
    words.push(w);
  }
  const t = f.toComplete;
  if (t && Object.keys(t.cost).length > 0) {
    let w = `To complete: the open children's estimates × ${ratio(t.ratio)}, as the `
      + `${plural(t.closed, "closed child", "closed children")} cost against theirs`;
    if (t.leadRatio > 0) w += `, plus ${percent(t.leadRatio)} for the lead`;
    w += ".";
    if (t.loaded) w += " All in adds the cost no issue links to.";
    words.push(w);
  }
  return words.length > 0 ? words.join(" ") : undefined;
}

/** A closed epic's first forecast against when it landed: "Forecast at its start: by Thu 5 Nov (85%: by Fri 6 Nov);
 * landed Thu 5 Nov, within the 85%". Undefined with no kept forecast or no close date. */
export function keptLine(f: LineageForecast, landed: WireDate | undefined, locale?: string, timeZone?: string): string | undefined {
  const k = f.kept;
  if (!k || !landed) return undefined;
  const hours = ms(k.p85) - ms(k.at) < twoDays;
  const d = (date: WireDate) => day(date, hours, locale, timeZone);
  const held = ms(landed) <= ms(k.p85) ? "within the 85%" : "after the 85%";
  return `Forecast at its start: by ${d(k.p50)} (85%: by ${d(k.p85)}); landed ${d(landed)}, ${held}`;
}

/** The kept forecast's help: "Made Wed 4 Nov for its 6 open children then, at the last 14 days' pace." */
export function keptHelp(f: LineageForecast, locale?: string, timeZone?: string): string | undefined {
  const k = f.kept;
  if (!k) return undefined;
  return `Made ${day(k.at, false, locale, timeZone)} for its ${plural(k.open, "open child", "open children")} then, `
    + `at the last ${k.windowDays} days' pace.`;
}

// Reports ▸ Planning ▸ Delivery (#5245, spec 5239-deploy-model, board 5): the four DORA figures for each target, a
// component in one environment, from deploys/delivery. The figures are counted on one tier, production unless the
// person picks another, and drawn dimmed, with the count, when fewer than 5 deploys ended in the range (note 18).
import type { DeployDeliveryTarget, EnvironmentTier, ReportRange } from "../protocol/generated";
import { spanWords } from "./delivery";
import { ranges } from "./reports";

/** The page's filters, after the "?" of #/reports/value/delivery. tier "" is every tier. */
export interface DeploysAsk { range: ReportRange; tier: EnvironmentTier | "" }

export const tiers: readonly EnvironmentTier[] = ["production", "staging", "testing", "development", "other"];

export const tierWords: Record<EnvironmentTier, string> = {
  production: "Production", staging: "Staging", testing: "Testing", development: "Development", other: "Other",
};

/** The Tier filter's choices: each tier, then every tier. */
export const tierOptions: readonly (readonly [EnvironmentTier | "", string])[] = [...tiers.map((t) => [t, tierWords[t]] as const), ["", "Every tier"]];

/** The filters an address names: the last 30 days and production when it names none. Day is not offered: a deploy a day is too few. */
export function parseDeploysQuery(query: string | undefined): DeploysAsk {
  const q = new URLSearchParams(query ?? "");
  const range = ranges.find((r) => r !== "day" && r === q.get("range")) ?? "month";
  const named = q.get("tier");
  const tier = named === "all" ? "" : tiers.find((t) => t === named) ?? "production";
  return { range, tier };
}

export function deploysQuery(a: DeploysAsk): string {
  return new URLSearchParams({ range: a.range, tier: a.tier || "all" }).toString();
}

/** Under this many deploys that ended, the figures are dimmed (board 5, note 18). */
export const fewDeploys = 5;

export interface DeployTile { key: string; title: string; value: string; detail: string }

const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;

/** A share in words: one decimal under 1% or for a fraction, else whole: "0.4%", "12.5%", "33%". */
function shareWords(v: number): string {
  const pct = v * 100;
  if (pct === 0 || pct === 100) return `${pct}%`;
  const one = Math.round(pct * 10) / 10;
  return pct < 1 || one !== Math.round(pct) && pct < 20 ? `${one}%` : `${Math.round(pct)}%`;
}

/** Deploys a week in words: "a day" from 14 a week (2 a day), as board 5 says the docs'. */
export function frequencyWords(perWeek: number | undefined): string {
  if (perWeek === undefined) return "—";
  if (perWeek >= 14) return `${Math.round(perWeek / 7)} a day`;
  return `${Math.round(perWeek * 10) / 10} a week`;
}

/** The four tiles of a target, in DORA's order. */
export function deployTiles(t: DeployDeliveryTarget): DeployTile[] {
  const went = t.deploymentFrequency.count;
  const lead = t.leadTime;
  const leadDetail = lead.count === 0 ? "no change is known to have gone out with a deploy yet"
    : [`median of ${plural(lead.count, "change", "changes")}`, ...lead.p90 !== undefined ? [`p90 ${spanWords(lead.p90)}`] : []].join(" · ");
  const failures = [`${t.failed} failed`, ...t.rollbacks > 0 ? [plural(t.rollbacks, "rollback", "rollbacks")] : []];
  const restore = t.recoveryTime;
  return [
    { key: "deploymentFrequency", title: "Deploy frequency", value: frequencyWords(t.deploymentFrequency.value),
      detail: `${plural(went, "deploy", "deploys")} went out` },
    { key: "leadTime", title: "Lead time for changes", value: lead.value === undefined ? "—" : spanWords(lead.value), detail: leadDetail },
    { key: "changeFailureRate", title: "Change failure rate", value: t.changeFailureRate.value === undefined ? "—" : shareWords(t.changeFailureRate.value),
      detail: `${failures.join(", ")} of ${plural(t.ended, "deploy", "deploys")}` },
    { key: "recoveryTime", title: "Time to restore",
      value: restore.value !== undefined ? spanWords(restore.value) : t.failed === 0 ? "No failure" : "—",
      detail: restore.count > 0 ? `median of ${plural(restore.count, "recovery", "recoveries")}`
        : t.failed === 0 ? "nothing to restore" : "not restored yet" },
  ];
}

/** A target's heading: "alexec/agents @ production". */
export const targetTitle = (t: DeployDeliveryTarget) => `${t.component} @ ${t.environment}`;

/** The line beside the heading: "21 deploys went out, 3 failed, in 30 days". */
export function targetLine(t: DeployDeliveryTarget, days: number): string {
  return `${plural(t.deploymentFrequency.count, "deploy", "deploys")} went out, ${t.failed} failed, in ${days} days`;
}

/** The note under a target with fewer than fewDeploys deploys that ended. */
export const fewWords = (t: DeployDeliveryTarget) =>
  `Too few deploys for a figure that means much (${t.ended}); shown dimmed.`;

/** The page's line under its title: "The last 30 days · Tier: production". */
export function askLine(rangeWords: string, a: DeploysAsk): string {
  return `${rangeWords} · Tier: ${a.tier ? a.tier : "every tier"}`;
}

export const deploysNote = "Lead time: a PR’s merge to the first deploy that brings it. Change failure rate: failed deploys and rollbacks, " +
  "of all deploys that ended. Time to restore: a failure, or a health signal seen in a deploy, to the next deploy that went out.";

export const resolvingWords = "Still asking the forge what some deploys brought: lead time can grow on the next read.";

export const noDeployMachine = "No machine of yours keeps deploys. Deploys come from the GitHub server’s deploy events; update a machine to count them.";

/** No target in the tier and range: the words, and how many there are in every tier when the person picked one. */
export function noTargetsWords(a: DeploysAsk, rangeWords: string, inEveryTier: number): string {
  const range = rangeWords.charAt(0).toLowerCase() + rangeWords.slice(1);
  if (!a.tier) return `No deploy ended in ${range}.`;
  return inEveryTier > 0
    ? `No deploy to a ${a.tier} environment ended in ${range}. ${plural(inEveryTier, "environment", "environments")} of other tiers had some: choose Every tier to see them.`
    : `No deploy to a ${a.tier} environment ended in ${range}.`;
}

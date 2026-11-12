// The outer loop in reach of an issue, a PR or a release (#3588, spec 3579-outer-loop), as one line
// of links under its title on its Work page, from one lineage/walk. Forward: the releases its PRs are
// part of, the CI runs that built them, their deploys and the health signals seen in them. Back ("what
// did this come from?"): the health signal an issue reports, the release and deploy it was seen in,
// and that release's PRs and the issues they fix; a release's own PRs and their issues. As Pipeline
// has it on the window.
import type { LineageGraph, LineageNode } from "../protocol/generated";
import { lineageUrl } from "./lineage";
import { shortRef } from "./work";
import { legacyRef } from "../protocol/ref";

/** How far its walk goes: issue, PR, release, deploy, health is 4 links. */
export const pipelineDepth = 4;
/** The most of one kind the line names; the rest are "2 more". */
const most = 3;

/** One stage on the line: its words, and its address outside Agents; no node for "2 more". */
export interface PipelineStep {
  node?: LineageNode;
  words: string;
  url?: string;
}

const same = (a: LineageNode, b: LineageNode) => a.kind === b.kind && a.ref === b.ref;
const has = (list: readonly LineageNode[], n: LineageNode) => list.some((m) => same(m, n));
const unique = (nodes: LineageNode[]) => nodes.filter((n, i) => nodes.findIndex((m) => same(m, n)) === i);

// The old form (#4800): the words and addresses below are made from it.
function split(full: string): [string, string] {
  const ref = legacyRef(full);
  const i = ref.indexOf(":");
  return i < 0 ? ["", ref] : [ref.slice(0, i), ref.slice(i + 1)];
}

/** "TestFlight 42", "App Store 1.2.0", "Cloud Run web-42", "Sentry issue 4321": a deploy's or a health
 * signal's name. */
export function stageWords(n: LineageNode): string {
  const [scheme, id] = split(n.ref);
  const last = id.split("/").pop() ?? id;
  if (n.kind === "deploy" && scheme === "testflight") return `TestFlight ${last}`;
  if (n.kind === "deploy" && scheme === "appstore") return `App Store ${last}`;
  if (n.kind === "deploy" && scheme === "cloudrun") return `Cloud Run ${last}`;
  if (n.kind === "health" && scheme === "sentry") return `Sentry issue ${last}`;
  return `${scheme} ${last}`;
}

/** Where a stage is outside Agents: a CI run's page, App Store Connect for a TestFlight build or an
 * App Store version (its address needs the app's Apple ID, which the ref does not say), a Cloud Run
 * service's revisions in the Google Cloud console (#3654), a Sentry issue on sentry.io, else the
 * forge's page for an issue, a PR or a release. */
export function stageUrl(n: LineageNode): string | undefined {
  const [scheme, id] = split(n.ref);
  if (n.kind === "ci-run" && scheme === "github") return "https://github.com/" + id.replace("/actions/run/", "/actions/runs/");
  if (n.kind === "ci-run" && scheme === "gitlab") return "https://gitlab.com/" + id.replace("/pipelines/", "/-/pipelines/");
  if (n.kind === "deploy" && (scheme === "testflight" || scheme === "appstore")) return "https://appstoreconnect.apple.com/apps";
  if (n.kind === "deploy" && scheme === "cloudrun") {
    // cloudrun:<project>/<region>/<service>/<revision>
    const m = /^([^/]+)\/([^/]+)\/([^/]+)\/[^/]+$/.exec(id);
    return m ? "https://console.cloud.google.com/run/detail/" + m[2] + "/" + m[3] + "/revisions?project=" + m[1] : undefined;
  }
  if (n.kind === "health" && scheme === "sentry") {
    const m = /^([^/]+)\/(.+)$/.exec(id);
    return m ? "https://sentry.io/organizations/" + m[1] + "/issues/" + m[2] + "/" : undefined;
  }
  return lineageUrl(n);
}

function capped(nodes: LineageNode[], words: (n: LineageNode) => string): PipelineStep[] {
  const named: PipelineStep[] = nodes.slice(0, most).map((n) => {
    const url = stageUrl(n);
    return url ? { node: n, words: words(n), url } : { node: n, words: words(n) };
  });
  return nodes.length > most ? [...named, { words: `${nodes.length - most} more` }] : named;
}

/** The line's stages, back then forward; empty when the walk reached none. */
export function pipelineSteps(node: LineageNode, g: LineageGraph): PipelineStep[] {
  // The nodes of a kind that are rel to (sources) or from (targets) any of these, each once, in the
  // walk's order (newest link first).
  const sources = (rel: string, kind: string, of: LineageNode[]) =>
    unique(g.links.filter((l) => l.rel === rel && l.from.kind === kind && has(of, l.to)).map((l) => l.from));
  const targets = (rel: string, kind: string, of: LineageNode[]) =>
    unique(g.links.filter((l) => l.rel === rel && l.to.kind === kind && has(of, l.from)).map((l) => l.to));
  const reported = node.kind === "issue" ? targets("reports", "health", [node]) : [];
  const seenIn = targets("seen-in", "release", reported);
  const origin = node.kind === "release" ? [node] : seenIn;
  const prs = sources("part-of", "pr", origin);
  const fixed = targets("fixes", "issue", prs).filter((n) => !same(n, node));
  const releases = node.kind === "issue" ? targets("part-of", "release", sources("fixes", "pr", [node])).filter((n) => !has(seenIn, n))
    : node.kind === "pr" ? targets("part-of", "release", [node])
    : node.kind === "release" ? [node] : [];
  const deploys = targets("deployed-as", "deploy", releases);
  const health = sources("seen-in", "health", [...releases, ...deploys]).filter((n) => !has(reported, n));
  return [
    ...capped(reported, (n) => `From ${stageWords(n)}`),
    ...capped(seenIn, (n) => `seen in ${shortRef(n.ref)}`),
    ...capped(targets("seen-in", "deploy", reported), stageWords),
    ...capped(prs, (n) => `PR ${shortRef(n.ref)}`),
    ...capped(fixed, (n) => shortRef(n.ref)),
    ...capped(releases.filter((n) => !same(n, node)), (n) => `Release ${shortRef(n.ref)}`),
    ...capped(sources("builds", "ci-run", releases), () => "CI run"),
    ...capped(deploys, stageWords),
    ...capped(health, stageWords),
  ];
}

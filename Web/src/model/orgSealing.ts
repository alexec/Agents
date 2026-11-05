// Console ▸ Model Access's sealing (#3397, specs/3397-client-sealing): the admin's page seals each of a route's
// secrets to each machine that may use it and to each admin's client, and sends only the envelopes. A save that
// changes where the key goes (the kind, the API or a setting) seals every value again: this page opens its own copy
// for those not typed anew. A value is in this page's memory only while it is sealed.
import type { OrgRoute, OrgRouteKept, OrgRouteSealed, SealRecipient } from "../protocol/generated";
import type { Link } from "../wire/link";
import { fingerprint, openItem, sealRoute } from "../wire/sealing";

/** An id made from a name, as the control plane makes one (routeIDFrom): Acme Bedrock is acme-bedrock. */
export function routeIDFrom(name: string): string {
  let out = "";
  let dash = false;
  for (const ch of name.toLowerCase()) {
    if (/[a-z0-9]/.test(ch)) {
      out += ch;
      dash = false;
    } else if (!dash && out.length > 0) {
      out += "-";
      dash = true;
    }
  }
  out = out.replace(/-+$/, "");
  return out.length > 40 ? out.slice(0, 40).replace(/-+$/, "") : out;
}

function settingsKey(route: OrgRoute): string {
  const s = route.settings ?? {};
  return JSON.stringify(Object.keys(s).sort().map((k) => [k, s[k as keyof typeof s]]));
}

/** Whether a save sends the key somewhere else: another kind, API or setting. */
export function bindingChanged(before: OrgRoute, after: OrgRoute): boolean {
  return before.kind !== after.kind || (before.vendor ?? "") !== (after.vendor ?? "") || settingsKey(before) !== settingsKey(after);
}

export const noCopyHere = "This browser has no copy of the route’s key yet, so it cannot seal it again. Type every key of the route, or save from an admin’s app that has one.";

/**
 * What orgRoutes/set or orgRoutes/replaceKey sends of a route's secrets: every field, sealed to every recipient, at
 * the next seal version. Undefined when the secrets stay as they are. fields are the secret fields the route's kind
 * takes; typed are the values typed now, which take the place of the ones kept.
 */
export async function sealedFor(link: Link, route: OrgRoute, kept: OrgRouteKept | null, typed: Record<string, string>,
  fields: readonly string[], signed: (recipients: SealRecipient[]) => Promise<SealRecipient[]> = async (r) => r,
): Promise<OrgRouteSealed | undefined | { problem: string }> {
  const keptFields = kept?.route.secretFields ?? [];
  const moved = kept !== null && bindingChanged(kept.route, route);
  if (Object.keys(typed).length === 0 && !(keptFields.length > 0 && moved)) return undefined;
  const values: Record<string, string> = {};
  const untyped = keptFields.filter((f) => fields.includes(f) && !(f in typed));
  if (kept && untyped.length > 0) {
    const record = await link.keyRecord();
    try {
      if (!record) throw new Error("unpaired");
      const mine = await openItem(record, await link.call("orgRoutes/sealed", { id: kept.route.id }));
      for (const f of untyped) if (mine[f] !== undefined) values[f] = mine[f]!;
    } catch {
      return { problem: noCopyHere };
    }
  }
  Object.assign(values, typed);
  // Each machine only when its owner's lock names its key (#3491, D7, D8).
  const recipients = await signed((await link.call("orgRoutes/recipients", { groups: route.groups ?? [] })).recipients);
  const sealVersion = (kept?.route.sealVersion ?? 0) + 1;
  const print: Record<string, string> = {};
  for (const [field, value] of Object.entries(values)) print[field] = await fingerprint(value);
  return {
    sealVersion, fingerprint: print,
    values: await sealRoute({ id: route.id, kind: route.kind, vendor: route.vendor, settings: route.settings }, values, sealVersion, recipients),
  };
}

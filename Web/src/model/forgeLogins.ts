// Settings ▸ Control plane ▸ GitHub, GitLab and Linear (#3160): the person's own logins, as the window's
// Settings ▸ Account has them (App/Sources/Settings/PersonSettingsSection.swift, #2951). Kept by the control plane.
import type { ForgeLogins, PeopleForViews } from "../protocol/generated";

export const forgeLoginsTitle = "GitHub, GitLab and Linear";
export const forgeLoginsFooter =
  "Named on the Pull requests, Merge requests and Issues pages’ Team section, and used to say an agent is on one of your own. Filled in from each machine’s own connection (Activity ▸ Connectors) when it is signed in; given here only when it is not.";
export const forgeLoginsNotSaved = "Your logins were not saved.";

export const forgeLoginFields = [
  { key: "github", label: "GitHub login" },
  { key: "gitlab", label: "GitLab login" },
  { key: "linear", label: "Linear login" },
] as const;

/** The caller's own logins from people/forViews, each blank when not given. */
export function myLogins(list: PeopleForViews): Required<ForgeLogins> {
  const me = list.people.find((p) => p.you === true);
  return { github: me?.githubLogin ?? "", gitlab: me?.gitlabLogin ?? "", linear: me?.linearLogin ?? "" };
}

/** What people/setForgeLogins is sent: each trimmed, blank to clear it, as the window sends. */
export function loginsToSave(logins: ForgeLogins): Required<ForgeLogins> {
  return { github: logins.github?.trim() ?? "", gitlab: logins.gitlab?.trim() ?? "", linear: logins.linear?.trim() ?? "" };
}

/** Whether a save would change what is kept. */
export function loginsChanged(kept: ForgeLogins, typed: ForgeLogins): boolean {
  const a = loginsToSave(kept), b = loginsToSave(typed);
  return a.github !== b.github || a.gitlab !== b.gitlab || a.linear !== b.linear;
}

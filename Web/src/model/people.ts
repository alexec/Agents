// Settings ▸ People's words and a machine's ask to join (#994, Team T1), as the window and the
// Remote have them: each client belongs to a person, each machine to one person. With one person,
// the local owner, nothing changes.
import type { ClientKind, Group, JoinRequest, PersonClient, PersonInvited, PersonMachine, PersonRemovePreview, PersonRow, UnpushedWork, UserRole } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import { managedBy, orgName, setBy, suspendedBy, waitingFirstSignIn } from "./signIn";

/** The roles, in the order the menu shows them. */
export const roles: UserRole[] = ["admin", "member"];

/** Under your own row, when the control plane gives a join command: a server joins as you with no code. */
export const joinCommandTitle = "Add a machine without a code";
export const joinCommandNote = "Run it on the machine. It shows a code; approve it here.";

/** A role in a person's words. */
export function roleWord(role: UserRole): string {
  return role === "admin" ? "Admin" : "Member";
}

/** What a role can do, under the Invite sheet's menu. */
export function roleNote(role: UserRole): string {
  return role === "admin"
    ? "An admin sees every person, invites people, changes roles and removes people."
    : "A member sees only their own machines and clients.";
}

/** The marks after a person's name: "You", "Local owner". */
export function badges(person: Pick<PersonRow, "you" | "localOwner">): string[] {
  return [...(person.you ? ["You"] : []), ...(person.localOwner ? ["Local owner"] : [])];
}

const clientKinds: Record<ClientKind, string> = { mac: "Mac window", iPhone: "iPhone", iPad: "iPad", browser: "Web page", unknown: "Client" };

/** A client: "MacBook Pro · Mac window". */
export function clientLine(client: PersonClient): string {
  const kind = clientKinds[client.kind] ?? "Client";
  return client.name && client.name !== kind ? `${client.name} · ${kind}` : kind;
}

/** A machine's state in a person's words: "Online", "Offline". */
export function stateWord(state: string): string {
  if (!state) return "Unknown";
  return state.charAt(0).toUpperCase() + state.slice(1).replace(/([a-z])([A-Z])/g, (_, a: string, b: string) => `${a} ${b.toLowerCase()}`);
}

/** A machine: "box-1 · Online · Linux". Nothing inside it is shown (FR-019). */
export function machineLine(machine: PersonMachine): string {
  return [machine.name, stateWord(machine.state), ...(machine.platform ? [machine.platform] : [])].join(" · ");
}

/** "2 machines", "1 client": a count with its noun. */
export function counted(n: number, noun: string): string {
  return `${n} ${noun}${n === 1 ? "" : "s"}`;
}

/** The sheet's words under an invite code. */
export function inviteNote(invited: Pick<PersonInvited, "expires" | "name">, locale?: string): string {
  const until = fromWireDate(invited.expires).toLocaleDateString(locale, { weekday: "long", month: "long", day: "numeric" });
  return `Works once, until ${until}. Send it to ${invited.name}; they paste it where a code is asked for in the Mac window or the Remote.`;
}

/** The empty People list, which an older control plane or a member with no machine sees. */
export const noPeople = "No people yet.";

/** The words for a member, who sees only themselves. */
export const memberNote = "You see only yourself. An admin invites people and changes roles.";

/** Rotate Control Key… (#997, spec 736 FR-043), as PeopleWords has it on the window and the Remote. */
export const rotateTitle = "Rotate the control key?";
export const rotateMessage = "Every client and machine connects again and takes the new key, with no new pairing. One that does not connect in the next 30 days has to pair again.";
export const rotateFoot = "Rotate the control plane’s key if you think someone copied it.";
export const rotated = "The control key was rotated. Each client and machine takes the new key when it connects again.";

/** What Remove takes away, a line each, for its confirmation. With the control plane's preview (#1763),
 * started machines are deleted, with the work on each that is not pushed; without one (an older control
 * plane), every machine is only taken off. */
export function removeLines(person: Pick<PersonRow, "name" | "clients" | "machines">, preview?: PersonRemovePreview | null): string[] {
  const lines: string[] = [];
  if (person.clients.length > 0) {
    lines.push(`${counted(person.clients.length, "client")} can no longer connect: ${person.clients.map((c) => c.name || clientKinds[c.kind]).join(", ")}.`);
  }
  if (preview) {
    const started = preview.startedMachines;
    if (started.length > 0) {
      lines.push(`${counted(started.length, "machine")} ${started.length === 1 ? "is" : "are"} stopped and deleted: ${started.map((m) => m.name).join(", ")}.`);
    }
    for (const machine of started) {
      if (machine.unknown) lines.push(machine.unknown);
      else if (machine.unpushed.length > 0) {
        lines.push(`On ${machine.name}, this work is not pushed and is lost: ${machine.unpushed.map(unpushedWords).join("; ")}.`);
      }
    }
    const registered = preview.registeredMachines;
    if (registered.length > 0) {
      lines.push(`${counted(registered.length, "machine")} ${registered.length === 1 ? "is" : "are"} taken off: ${registered.map((m) => m.name).join(", ")}.`);
    }
  } else if (person.machines.length > 0) {
    lines.push(`${counted(person.machines.length, "machine")} ${person.machines.length === 1 ? "is" : "are"} taken off: ${person.machines.map((m) => m.name).join(", ")}.`);
  }
  if (lines.length === 0) lines.push(`${person.name} has no clients or machines.`);
  return lines;
}

/** "agents/fix (2 commits not pushed, changes not committed)", as PeopleWords.unpushedWords has it. */
export function unpushedWords(work: UnpushedWork): string {
  const name = work.branch ?? work.worktree.replace(/\/+$/, "").split("/").pop() ?? work.worktree;
  const what: string[] = [];
  if (work.ahead !== undefined && work.ahead > 0) what.push(`${work.ahead} ${work.ahead === 1 ? "commit" : "commits"} not pushed`);
  else if (work.ahead === undefined && work.unmerged !== undefined && work.unmerged > 0) {
    what.push(`${work.unmerged} ${work.unmerged === 1 ? "commit" : "commits"} never pushed`);
  }
  if (work.uncommitted !== undefined && work.uncommitted > 0) what.push("changes not committed");
  return what.length === 0 ? name : `${name} (${what.join(", ")})`;
}

/** Said while Remove asks the person's machines what work on them is not pushed. */
export function askingLine(name: string): string {
  return `Asking ${name}’s machines what work on them is not pushed…`;
}

/** Remove's check failed (#2193), as PeopleWords.checkFailed: `why` is a sentence. Remove stays off until it works. */
export function checkFailedLine(name: string, why: string): string {
  return `Could not check what ${name}’s machines would lose. ${why} Removing ${name} stops and deletes `
    + `the machines ${name} started, with any work on them not pushed, so Remove stays off until the check works.`;
}

/** The title of the Remove confirmation. */
export function removeTitle(name: string): string {
  return `Remove ${name}?`;
}

/** A machine's ask to join, after its name: "wants to join as you". */
export function joinWords(request: Pick<JoinRequest, "for" | "forName">, you: string | undefined): string {
  if (!request.for) return "wants to join. It names no person.";
  if (you !== undefined && request.for === you) return "wants to join as you";
  return `wants to join as ${request.forName || request.for}`;
}

/** The line that asks the person to check the code. */
export function codeLine(code: string): string {
  return `Check that the machine shows ${code}`;
}

/** What Approve and Deny do, under the buttons. */
export const joinExplanation = "Approve adds the machine to the control plane. Deny refuses it; it can ask again.";

/** A request said again replaces the one before it; a new one goes at the end. */
export function withJoin(list: readonly JoinRequest[], request: JoinRequest): JoinRequest[] {
  const at = list.findIndex((r) => r.request === request.request);
  if (at < 0) return [...list, request];
  const out = [...list];
  out[at] = request;
  return out;
}

/** A request decided or answered goes. */
export function withoutJoin(list: readonly JoinRequest[], request: string): JoinRequest[] {
  return list.filter((r) => r.request !== request);
}

/** The requests not yet expired at `now`. */
export function liveJoins(list: readonly JoinRequest[], now: Date = new Date()): JoinRequest[] {
  return list.filter((r) => fromWireDate(r.expires).getTime() > now.getTime());
}

/** You first, then the local owner, then by name: the order Settings ▸ People shows. */
export function ordered(people: readonly PersonRow[]): PersonRow[] {
  const rank = (p: PersonRow) => (p.you ? 0 : p.localOwner ? 1 : 2);
  return [...people].sort((a, b) => rank(a) - rank(b) || a.name.localeCompare(b.name));
}

/**
 * Whether the role menu may change this person's role: an admin may change anyone's, except the
 * last admin's (the server refuses that too, with its own words).
 */
export function canSetRole(person: PersonRow, people: readonly PersonRow[], admin: boolean): boolean {
  if (!admin) return false;
  // A role a provider's SCIM group gives is the provider's to change (#1002, FR-020): managedByProvider.
  if ((person.roleFrom?.length ?? 0) > 0) return false;
  const admins = people.filter((p) => p.role === "admin").length;
  return !(person.role === "admin" && admins <= 1);
}

/** Whether Remove is offered: an admin, for anyone but themselves and the local owner. */
export function canRemove(person: PersonRow, admin: boolean): boolean {
  return admin && !person.you && !person.localOwner;
}

/**
 * The org provider lines under a person (#1002, FR-028), with `names` giving a provider's name by
 * its id: Managed by, Waiting for first sign-in, Suspended by.
 */
export function orgLines(person: Pick<PersonRow, "scim" | "provisioned" | "suspended">, names: Readonly<Record<string, string>>): string[] {
  const lines: string[] = [];
  if (person.scim) lines.push(managedBy(orgName(person.scim.provider, names)));
  if (person.provisioned) lines.push(waitingFirstSignIn);
  if (person.suspended) lines.push(suspendedBy(orgName(person.suspended.provider, names)));
  return lines;
}

/**
 * "Set by Okta" on a role a provider's SCIM group gives (FR-020, FR-028): the provider of the first
 * of `roleFrom` that the groups know, else the person's own SCIM provider. Null for a role set by hand.
 */
export function roleSetBy(person: Pick<PersonRow, "roleFrom" | "scim">, groups: readonly Group[], names: Readonly<Record<string, string>>): string | null {
  const from = person.roleFrom ?? [];
  if (from.length === 0) return null;
  const provider = from.map((id) => groups.find((g) => g.id === id)?.source?.scim).find((p) => p !== undefined)
    ?? person.scim?.provider ?? from[0]!;
  return setBy(orgName(provider, names));
}

/** Whether a person has anything an org provider controls: an admin is offered Edit in Console for it. */
export function providerManaged(person: Pick<PersonRow, "scim" | "provisioned" | "suspended" | "roleFrom">): boolean {
  return person.scim !== undefined || person.provisioned === true || person.suspended !== undefined || (person.roleFrom?.length ?? 0) > 0;
}

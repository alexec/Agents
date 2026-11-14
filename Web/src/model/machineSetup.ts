// New Machine in one step (#5204), as the Swift MachineSetups: the sheet asks for the folders to clone and the
// runtime to sign in, with the machine. The control plane clones the folders once it joins; the sign-in needs the
// person's browser, so the page that made the machine keeps it here and opens the runtime's sign-in by itself once
// the machine has joined and its runtime is installed.
import type { RuntimeStatus } from "../protocol/generated";
import { offersMachineSignIn } from "./runtimes";

/** The runtimes New Machine offers to sign in: the ones a server signs in from a client (#3349), Claude first. */
export const signInRuntimes: { id: string; name: string }[] = [
  { id: "claude", name: "Claude" },
  { id: "codex", name: "Codex" },
];

/** The folders field's prompt. */
export const clonesPrompt = "Git addresses, one a line";

/** How long a machine is waited for: a first boot and the runtimes' install take minutes. */
export const setupWait = 30 * 60_000;

export interface PendingSignIn { runtimeID: string; since: number }

export type SetupStep = { wait: true } | { signIn: RuntimeStatus } | { done: true };

/** What to do for a machine that joined, from its runtimes as it lists them; `canSignIn` is `runtimes.signIn.1`. */
export function setupStep(runtimeID: string, runtimes: RuntimeStatus[] | undefined, canSignIn: boolean): SetupStep {
  const status = runtimes?.find((r) => r.runtime.id === runtimeID);
  if (!status) return { wait: true };
  const a = status.availability;
  if ("installing" in a || "missing" in a) return { wait: true };
  if ("failed" in a || "installFailed" in a) return { done: true };
  if (!canSignIn || !status.signIn) return { done: true };
  return offersMachineSignIn(status) ? { signIn: status } : { done: true };
}

/** The sign-ins New Machine asked for, by the machine's name, until each is done or its wait is over. */
export class MachineSetups {
  readonly signIns = new Map<string, PendingSignIn>();

  made(name: string, runtimeID: string | null, now = Date.now()): void {
    if (runtimeID) this.signIns.set(name, { runtimeID, since: now });
    else this.signIns.delete(name);
  }

  done(name: string): void { this.signIns.delete(name); }

  /** The machines that wait to be signed in and have joined, by their names; drops the waits that are over. */
  joined(names: string[], now = Date.now()): { name: string; runtimeID: string }[] {
    for (const [name, p] of this.signIns) if (now - p.since >= setupWait) this.signIns.delete(name);
    return names.flatMap((name) => {
      const p = this.signIns.get(name);
      return p ? [{ name, runtimeID: p.runtimeID }] : [];
    });
  }
}

// Part of the Store (#5384): machines.
import type { MachineRef, KeptRequest, ProviderID, StartedMachinePreview } from "../../protocol/generated";
import { CallFailed } from "../../wire/link";
import { describe } from "../errors";
import { log } from "../../log";
import { canJoin, type MachineJoin, type MachineMaking } from "../machineRow";
import type { Store } from "../store";
import { type NewMachineDraft } from "./shared";

export const machinesMethods = {
  async startHost(this: Store, host: string): Promise<void> {
    if (this.hostsBeingStarted.value.includes(host)) return;
    this.hostsBeingStarted.value = [...this.hostsBeingStarted.value, host];
    try {
      const row = await this.link.call("machines/start", { host: host as MachineRef });
      this.takeHostRow(row);
    } catch (error) {
      log("call.failed", error instanceof CallFailed ? error.code : undefined);
      this.say(describe(error));
    } finally {
      this.hostsBeingStarted.value = this.hostsBeingStarted.value.filter((h) => h !== host);
    }
  },
  /** Remove… on a machine (#3381): it stops connecting, and its agents are left running where they are. */
  async removeHost(this: Store, host: string): Promise<void> {
    try {
      await this.link.call("machines/remove", { host: host as MachineRef });
      this.takeHosts(this.hosts.value.filter((h) => h.id !== host));
      this.forgetHost(host);
    } catch (error) {
      this.say(describe(error));
    }
  },
  /** New Machine (#3974, #4634): the sheet, on the default provider or the one New Machine on names, with every
   * field on what New Machine would make (the options used last there, else its first choices). Make confirms it. */
  newMachine(this: Store, provider?: string): void {
    this.newMachineAsk.value = provider ? { provider } : {};
  },
  /** Make on the New Machine sheet (#4634): the sheet has closed, and the machine's row says Making until it joins.
   * A make the provider refuses opens the sheet again on the same choices, with the provider's reason. */
  async makeMachine(this: Store, draft: NewMachineDraft): Promise<void> {
    const making = "";
    this.machinesMaking.value = [...this.machinesMaking.value, making];
    const drop = (name: string) => {
      const at = this.machinesMaking.value.indexOf(name);
      if (at >= 0) this.machinesMaking.value = this.machinesMaking.value.filter((_, i) => i !== at);
    };
    const refused = (problem: string) => { this.newMachineAsk.value = { provider: draft.provider, again: draft, problem }; };
    try {
      const made = await this.link.call("providers/create", { id: draft.provider as ProviderID, name: draft.name, options: draft.options });
      drop(making);
      if (made.workspace.state === "failed") {
        refused(made.workspace.reason || `Could not make ${made.workspace.name}.`);
        return;
      }
      this.machinesMaking.value = [...this.machinesMaking.value, made.workspace.name];
      // A row is drawn for it until a machine of that name joins, or ten minutes at most.
      setTimeout(() => drop(made.workspace.name), 10 * 60_000);
    } catch (error) {
      drop(making);
      refused(describe(error));
    }
  },
  /** Delete on a machine New Machine made that never joined (#4610): the provider deletes the workspace. */
  /**
   * A click on a machine that never joined (#4978), as the window's joinMachine: the control plane installs Agents on it
   * over ssh, from the machine that carries its provider for a codespace (`gh codespace ssh` starts a stopped one), after
   * its provider starts it otherwise; it is linked to its workspace once it joins. The row says each step, and why it
   * failed. `trust` is a host key the person looked at and trusts.
   */
  async joinMachine(this: Store, row: MachineMaking, trust?: string): Promise<void> {
    const key = `${row.provider}/${row.workspace}`;
    const now = this.machineJoins.value[key];
    if (!canJoin(row) || (now && "joining" in now)) return;
    const set = (join: MachineJoin | null) => {
      const next = { ...this.machineJoins.value };
      if (join) next[key] = join; else delete next[key];
      this.machineJoins.value = next;
    };
    set({ joining: null });
    const outcome = await this.providers.install(row.ssh ?? "", row.name, row.provider, row.workspace, trust);
    if ("needsTrust" in outcome) set({ needsTrust: outcome.needsTrust });
    else if ("failed" in outcome) set({ failed: outcome.failed });
    else set({ joining: "started" });
  },
  /** Forgets a join's host key question: the person did not trust it. */
  cancelJoin(this: Store, row: MachineMaking): void {
    const next = { ...this.machineJoins.value };
    delete next[`${row.provider}/${row.workspace}`];
    this.machineJoins.value = next;
  },
  /** `control/installProgress`: the step of a join, on the row of its name. */
  heardInstallStep(this: Store, params: { name?: string; step?: string } | null): void {
    if (!params?.name || !params.step) return;
    for (const w of (this.providers.list.value ?? []).flatMap((p) => p.workspaces.map((x) => ({ p: p.id, x })))) {
      const key = `${w.p}/${w.x.id}`;
      const now = this.machineJoins.value[key];
      if (w.x.name === params.name && now && "joining" in now) {
        this.machineJoins.value = { ...this.machineJoins.value, [key]: { joining: params.step } };
      }
    }
  },
  async deleteWorkspace(this: Store, provider: string, workspace: string): Promise<void> {
    try {
      await this.link.call("providers/deleteWorkspace", { id: provider as ProviderID, workspace });
    } catch (error) {
      this.say(describe(error));
    }
  },
  /** Check Again on a machine's row (#3979): the control plane asks it how it is now. */
  async checkAgain(this: Store, host: string): Promise<void> {
    try {
      await this.link.call("machines/checkAgain", { host: host as MachineRef });
    } catch (error) {
      this.say(describe(error));
    }
  },
  /** Delete's question (#3979): the worktrees on the machine with work not pushed; null when it can't be asked. */
  async deletePreview(this: Store, host: string): Promise<StartedMachinePreview | null> {
    return this.link.call("machines/deletePreview", { host: host as MachineRef }).catch(() => null);
  },
  /** Delete… on a machine a provider made (#3974): the provider deletes it, then the host goes as Remove does. */
  async deleteHost(this: Store, host: string): Promise<void> {
    try {
      await this.link.call("machines/deleteMachine", { host: host as MachineRef });
      this.takeHosts(this.hosts.value.filter((h) => h.id !== host));
      this.forgetHost(host);
    } catch (error) {
      this.say(describe(error));
    }
  },
  /** × on a kept prompt: it isn't sent, and the workspace keeps starting (US3 AS3). */
  async dropKept(this: Store, kept: KeptRequest): Promise<void> {
    this.kept.value = this.kept.value.filter((k) => k.id !== kept.id);
    await this.link.call("machines/dropKept", { host: kept.host, id: kept.id }).catch((error: unknown) => this.say(describe(error)));
  },
  /** Try Again on one that wasn't sent: kept again, and the workspace started. */
  async retryKept(this: Store, kept: KeptRequest): Promise<void> {
    await this.link.call("machines/retryKept", { host: kept.host, id: kept.id }).catch((error: unknown) => this.say(describe(error)));
  },
};

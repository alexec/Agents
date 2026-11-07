// The control plane's machine providers as this page holds them (#1808), as the window's
// ControlSettingsModel: listed when Settings opens, kept by control/providersChanged, and each
// change sent to the control plane. Secrets pass through in a request and are not kept here.
import { signal } from "@preact/signals";
import type { ControlMachine, Group, MachineRef, ProviderAdd, ProviderID, ProviderSummary } from "../protocol/generated";
import { Failure } from "../protocol/generated";
import type { Caller } from "../protocol/methods";
import { CallFailed, LinkDown } from "../wire/link";
import { describe } from "./errors";
import { providerWords } from "./machineProviders";

/** A Stop that agents at work hold back: what to ask before stopping anyway (US4 AS4). */
export interface StopAsk {
  host: string;
  question: string;
}

/** What Link to Machine… came to: linked, a host key to look at first, or why not. */
export type LinkOutcome = { linked: true } | { needsTrust: string } | { failed: string };

/** What Add as Machine… came to: installed under a name, a host key to look at first, or why not. */
export type InstallOutcome = { added: string } | { needsTrust: string } | { failed: string };

export class Providers {
  /** As last listed; null before the first list. */
  readonly list = signal<ProviderSummary[] | null>(null);
  /** Why there are none to show: a list that failed. */
  readonly problem = signal<string | null>(null);
  /** Why this control plane runs no providers, in its own words (several copies, or no folder for their secrets, #3113). */
  readonly off = signal<string | null>(null);
  /** The groups providers are given to (#1761): every one for an admin, a member's own. Empty from a control plane before groups. */
  readonly groups = signal<Group[]>([]);

  constructor(private readonly caller: Caller) {}

  /** `control/providersChanged`. */
  take(params: unknown): void {
    const providers = (params as { providers?: ProviderSummary[] } | null)?.providers;
    if (Array.isArray(providers)) this.list.value = providers;
  }

  /** Lists them, and asks every provider to list again (FR-004), as the page opens. */
  async load(): Promise<void> {
    try {
      this.list.value = (await this.caller.call("providers/list", {})).providers;
      this.problem.value = null;
      this.off.value = null;
      await this.loadGroups();
    } catch (error) {
      this.list.value = [];
      if (error instanceof CallFailed && error.code === Failure.providersNeedOneCopy) this.off.value = error.message || providerWords.off;
      else this.problem.value = describe(error);
      return;
    }
    await this.refresh();
  }

  /** List Again: one provider, or every one. The new list comes as control/providersChanged. */
  async refresh(id?: string): Promise<void> {
    await this.caller.call("providers/refresh", id ? { id: id as ProviderID } : {}).catch(() => undefined);
  }

  /** Add or Save. Answers null, or why the control plane refused it, to say in the sheet. */
  async save(request: ProviderAdd): Promise<string | null> {
    try {
      const saved = await this.caller.call(request.id ? "providers/update" : "providers/add", request);
      const list = this.list.value ?? [];
      this.list.value = list.some((p) => p.id === saved.id) ? list.map((p) => (p.id === saved.id ? saved : p)) : [...list, saved];
      return null;
    } catch (error) {
      return describe(error);
    }
  }

  /** `groups/list`, again on each control/groupsChanged (#1761). */
  async loadGroups(): Promise<void> {
    this.groups.value = (await this.caller.call("groups/list", {}).catch(() => null))?.groups ?? [];
  }

  /** Gives a provider to a group, or with none to the admins alone (#1761). */
  async setGroup(provider: string, group: string | null): Promise<string | null> {
    try {
      await this.caller.call("providers/setGroup", group ? { provider: provider as ProviderID, group } : { provider: provider as ProviderID });
      return null;
    } catch (error) {
      return describe(error);
    }
  }

  async remove(id: string): Promise<string | null> {
    try {
      await this.caller.call("providers/remove", { id: id as ProviderID });
      this.list.value = (this.list.value ?? []).filter((p) => p.id !== id);
      return null;
    } catch (error) {
      return describe(error);
    }
  }

  /**
   * Link to Machine: `host` runs on `workspace` of `provider`. A machine that joined with the
   * command has no host key trusted yet (#3379): its fingerprint comes back to show, and `trust`
   * is that fingerprint once the person said it is the one the machine shows.
   */
  async link(host: string, provider: string, workspace: string, startWhenUsed: boolean, stopWhenIdleMinutes: number,
    trust?: string): Promise<LinkOutcome> {
    try {
      await this.caller.call("machines/link", {
        host: host as MachineRef, provider: provider as ProviderID, workspace, startWhenUsed, stopWhenIdleMinutes,
        ...(trust ? { trust } : {}),
      });
      return { linked: true };
    } catch (error) {
      const fingerprint = error instanceof CallFailed && error.code === Failure.hostKeyToTrust
        ? (error.data as { fingerprint?: string } | undefined)?.fingerprint : undefined;
      if (fingerprint) return { needsTrust: fingerprint };
      return { failed: describe(error) };
    }
  }

  /** The machines Add as Machine… installed, by name, linked to their workspace once they join. */
  private readonly linkOnJoin = new Map<string, { provider: string; workspace: string; trust?: string | undefined }>();

  /**
   * Add as Machine… (#3365), as the window's: the control plane installs Agents on `workspace` over
   * its own ssh, or a codespace from the machine that carries its provider (#3497), and the machine
   * is linked to it once it joins, so its
   * provider starts it again (#3348). `trust` is the host key's fingerprint, when the person said
   * it is the one the machine shows.
   */
  async install(destination: string, name: string, provider: string, workspace: string, trust?: string): Promise<InstallOutcome> {
    // Linked on join from the start (#3377): when the page stops waiting, the install goes on and
    // the machine still joins.
    // The key trusted for the install is the one the link keeps (#3379).
    const asked = name || destination;
    this.linkOnJoin.set(asked, { provider, workspace, trust });
    try {
      // The provider and workspace let the control plane install a carried codespace from its
      // carrying machine, with the token kept there (#3497).
      const answer = await this.caller.call("machines/install", {
        destination, name, provider: provider as ProviderID, workspace, ...(trust ? { trust } : {}),
      }) as
        { needsTrust?: string; name?: string } | null;
      this.linkOnJoin.delete(asked);
      if (answer?.needsTrust) return { needsTrust: answer.needsTrust };
      const joined = answer?.name || asked;
      this.linkOnJoin.set(joined, { provider, workspace, trust });
      return { added: joined };
    } catch (error) {
      if (!(error instanceof LinkDown)) this.linkOnJoin.delete(asked);
      return { failed: describe(error) };
    }
  }

  /** On each list of hosts: links the ones Add as Machine… installed that have joined since. */
  linkJoined(hosts: readonly ControlMachine[]): void {
    for (const [name, wanted] of this.linkOnJoin) {
      const host = hosts.find((h) => h.name === name && !h.workspace);
      if (!host) continue;
      this.linkOnJoin.delete(name);
      void this.caller.call("machines/link", {
        host: host.id as MachineRef, provider: wanted.provider as ProviderID, workspace: wanted.workspace,
        ...(wanted.trust ? { trust: wanted.trust } : {}),
      })
        .catch(() => undefined);
    }
  }

  /** Stop when idle, in minutes, of a linked machine; 0 is Never (#3729). */
  async setIdle(host: string, stopWhenIdleMinutes: number): Promise<string | null> {
    try {
      await this.caller.call("machines/setMachineOptions", { host: host as MachineRef, stopWhenIdleMinutes });
      return null;
    } catch (error) {
      return describe(error);
    }
  }

  async unlink(host: string): Promise<string | null> {
    try {
      await this.caller.call("machines/unlink", { host: host as MachineRef });
      return null;
    } catch (error) {
      return describe(error);
    }
  }

  /**
   * Stop. With agents at work there and no `confirmed`, answers the question to ask first;
   * otherwise null, or why the control plane refused it.
   */
  async stop(host: string, confirmed = false): Promise<StopAsk | string | null> {
    try {
      await this.caller.call("machines/stop", confirmed ? { host: host as MachineRef, confirmRunning: true } : { host: host as MachineRef });
      return null;
    } catch (error) {
      if (!confirmed && error instanceof CallFailed && error.code === Failure.agentsWorking) return { host, question: error.message };
      return describe(error);
    }
  }
}

// Part of the Store (#5384): controlPlane.
import type { Agent } from "../../protocol/generated";
import { sealWork } from "../../wire/sealing";
import { describe } from "../errors";
import { fromWireDate } from "../../protocol/dates";
import { openCaps } from "../teamGroups";
import { knowPublicViews } from "../../place";
import { hostAnswers } from "../capabilities";
import { Capability } from "../../protocol/capabilities.generated";
import { providerManaged, withoutJoin } from "../people";
import { orgNames } from "../signIn";
import { withoutRequest } from "../channelLinks";
import { withoutSignIn } from "../signIn";
import type { Store } from "../store";

export const controlPlaneMethods = {
  /**
   * Seals what waits for a copy that this page can make (#3397): a machine that joined, or a
   * client paired, after a route or a secret was sealed. At each connection and on
   * control/sealingWanted. The values are opened here, in memory, and never kept.
   */
  async sealWaiting(this: Store): Promise<void> {
    if (!this.planeHas(Capability.sealing1)) return;
    const record = await this.link.keyRecord();
    const work = record ? await this.link.call("sealing/work", {}).catch(() => null) : null;
    if (!record || !work || work.items.length === 0) return;
    const checked = { items: await Promise.all(work.items.map(async (item) => ({ ...item, missing: await this.signedRecipients(item.missing) }))) };
    const items = await sealWork(record, { items: checked.items.filter((item) => item.missing.length > 0) });
    if (items.length > 0) await this.link.call("sealing/add", { items }).catch(() => undefined);
  },
  /**
   * The recipients this page may seal a secret to (#3491, D8): a machine only when its owner's
   * lock names its key. A control plane before the lock has none to check against.
   */
  async signedRecipients<R extends { id: string; owner?: string; publicKey: string }>(this: Store, recipients: R[]): Promise<R[]> {
    return this.planeHas(Capability.lock1) ? this.machineLock.signed(recipients) : recipients;
  },
  /** The machine lock's check and join (#3490), at each connection; a control plane before it has none. */
  async lockStep(this: Store): Promise<void> {
    if (this.planeHas(Capability.lockJoin1)) await this.machineLock.run();
  },
  /** A workflow's newest runs, including archived sessions, in a growing page. */
  async loadWorkflowRuns(this: Store, host: string, folder: string, workflowID: string, limit: number): Promise<Agent[]> {
    const listed = await this.link.call("agents/list", {
      includeArchived: true, archivedCommands: false, archivedOnly: false, folder: folder as never,
      startedByWorkflow: workflowID, lean: true, limit,
    }, host).catch(() => null);
    if (!listed) return [];
    this.addAgents(listed, host);
    return listed;
  },
  /**
   * Everything again, on every connection, in the window's order (refreshEverything): agents,
   * then folders, then the cards and the open conversation at once. No cursors on the wire.
   * One at a time: asked again while running, it runs once more after.
   */
  load(this: Store): Promise<void> {
    return this.once("*", async () => {
      const [hosts] = await Promise.all([this.link.call("machines/list", {}), this.loadPlane(), this.loadKept(), this.loadJoinRequests(),
        this.loadPeople().then(() => Promise.all([this.loadLinkRequests(), this.loadGovernanceRequests(), this.loadBudgetRequests(),
          this.loadRemoveRequests()])),
        this.loadSignInRequests()]);
      this.takeHosts(hosts);
      // A machine this device's copy drew that the control plane no longer lists goes (#4790).
      for (const host of this.fromDevice.value) {
        if (hosts.some((h) => h.id === host)) continue;
        this.forgetHost(host);
        this.answered(host);
      }
      // This page's place in its lock first: a machine that holds the lock takes a call only
      // on a channel this page opens with its lock key (#3492).
      await this.lockStep().catch(() => undefined);
      await Promise.all(this.hosts.value.filter((host) => hostAnswers(host.state)).map((host) => this.onHost(host.id, async () => {
        // A removal that landed while this waited is not loaded back (#291).
        if (!this.hostIsOnline(host.id)) return;
        await this.loadHost(host.id);
      })));
      // One offline or stopped now lists what it last did, greyed, as the window keeps it (#962).
      await Promise.all(this.hosts.value.filter((host) => !hostAnswers(host.state))
        .map((host) => this.onHost(host.id, () => this.loadLastHeard(host.id))));
      const watching = this.watching.value;
      if (watching) await this.loadTranscript(watching.host, watching.session);
    });
  },
  /** What the control plane keeps for stopped workspaces; one without providers keeps nothing. */
  async loadKept(this: Store): Promise<void> {
    const listed = await this.link.call("machines/listKept", {}).catch(() => null);
    this.kept.value = listed?.kept ?? [];
  },
  /** The control plane's status, for this Mac's host notice; a plane that can't say leaves it as it was. */
  async loadPlane(this: Store): Promise<void> {
    const status = await this.link.call("control/status", {}).catch(() => null);
    if (!status) return;
    this.plane.value = { machineID: status.machineID, homeHost: status.homeHost, thisMacHost: status.thisMacHost,
      name: status.name, version: status.version, required: status.required, capabilities: status.capabilities,
      startedAt: status.startedAt, web: status.web, restartable: status.restartable, publicWeb: status.publicWeb };
    this.person.value = status.person ?? null;
    this.joinCommand.value = status.joinCommand || null;
    knowPublicViews(status.publicViews);
    this.knowVersions();
    // The window on the Mac that moves the control plane says its rows, if one is open (#4255).
    if (this.planeHas(Capability.controlPlaneMove1) && status.person?.role === "admin") {
      this.askPlaneMove({ action: "status" }).catch(() => {});
    }
  },
  /** Machines waiting to join (#994); a control plane before it has none to say. */
  async loadJoinRequests(this: Store): Promise<void> {
    const listed = await this.link.call("machines/joinRequests", {}).catch(() => null);
    this.joinRequests.value = listed ?? [];
  },
  /** GitHub sign-ins waiting (#995); a control plane before sign-in has none to say. */
  async loadSignInRequests(this: Store): Promise<void> {
    const listed = await this.link.call("signIn/requests", {}).catch(() => null);
    this.signInRequests.value = listed ?? [];
  },
  /**
   * Approve or deny a GitHub sign-in on a new client (#995). The card goes at once; a refusal is
   * said, and the card stays.
   */
  async decideSignIn(this: Store, request: string, approve: boolean, code?: string): Promise<void> {
    try {
      await this.link.call(approve ? "signIn/approve" : "signIn/deny", code === undefined ? { request } : { request, code });
      this.signInRequests.value = withoutSignIn(this.signInRequests.value, request);
    } catch (error) {
      this.say(describe(error));
    }
  },
  /**
   * The one people list (#2055), and the groups the first time: every view reads these. A control plane before
   * people has none.
   */
  async loadPeople(this: Store): Promise<void> {
    try {
      this.people.value = await this.link.call("people/list", {});
      this.peopleAt.value = Date.now();
      this.peopleFailure.value = null;
    } catch (error) {
      this.peopleFailure.value = error;
      return;
    }
    if (this.providers.groups.value.length === 0) await this.providers.loadGroups();
    this.keepCapsTrue();
    await this.loadOrgNames();
  },
  /** The org providers' names (#1002), once, when a person or a group names one; an older control plane has none. */
  async loadOrgNames(this: Store): Promise<void> {
    if (this.orgNamesRead) return;
    const named = (this.people.value?.people ?? []).some(providerManaged) || this.providers.groups.value.some((g) => g.source);
    if (!named) return;
    this.orgNamesRead = true;
    const providers = await this.link.call("signIn/providers", {}).catch(() => null);
    if (providers) this.orgProviderNames.value = orgNames(providers.orgProviders);
    else this.orgNamesRead = false;
  },
  /** Drops the cap notices no longer true (#2073), and wakes when the next one's day ends. */
  keepCapsTrue(this: Store): void {
    const open = openCaps(this.capped.value, this.people.value?.people ?? null, this.providers.groups.value);
    if (open.length !== this.capped.value.length) this.capped.value = open;
    if (this.capExpiry) clearTimeout(this.capExpiry);
    this.capExpiry = null;
    if (open.length === 0) return;
    const next = Math.min(...open.map((n) => fromWireDate(n.until).getTime()));
    this.capExpiry = setTimeout(() => this.keepCapsTrue(), Math.max(1000, next - Date.now()));
  },
  /** An admin's requests for an MCP server or skill (#2019, M5); a control plane before them has none. */
  async loadGovernanceRequests(this: Store): Promise<void> {
    const admin = this.people.value?.admin ?? false;
    const listed = admin ? await this.link.call("governance/requests", {}).then((l) => l.requests, () => []) : [];
    // An admin's own decided ones come too, for Settings ▸ Policy: the Console has the waiting ones.
    this.governanceRequests.value = listed.filter((r) => r.state === "waiting");
  },
  /** An admin's Ask for More requests of today waiting (#3262); a member, or a control plane before them, has none. */
  async loadBudgetRequests(this: Store): Promise<void> {
    const admin = this.people.value?.admin ?? false;
    const listed = admin ? await this.link.call("policy/requests", {}).then((l) => l.requests, () => []) : [];
    this.budgetRequests.value = listed.filter((r) => r.state === "waiting");
  },
  /** An admin's SCIM removals waiting (#1002, #2436); a member, or a control plane before SCIM, has none. */
  async loadRemoveRequests(this: Store): Promise<void> {
    const admin = this.people.value?.admin ?? false;
    this.removeRequests.value = admin ? await this.link.call("people/removeRequests", {}).then((r) => r.requests, () => []) : [];
  },
  /** Link requests (#1762), and for an admin whom to send them on to; a control plane before links has none. */
  async loadLinkRequests(this: Store): Promise<void> {
    const listed = await this.link.call("links/requests", {}).catch(() => null);
    this.linkRequests.value = listed ?? [];
    const people = this.people.value;
    this.linkPeople.value = people?.admin ? people.people.filter((p) => p.kind === "person") : [];
  },
  /**
   * Approve, deny or send on a channel link's request (#1762). `to` is the person an admin sends a
   * request that names nobody on to. The card goes at once; a refusal is said, and the card stays.
   */
  async decideLink(this: Store, request: string, approve: boolean, to?: string): Promise<void> {
    try {
      await this.link.call(approve ? "links/approve" : "links/deny", { request, ...(to ? { for: to } : {}) });
      this.linkRequests.value = withoutRequest(this.linkRequests.value, request);
    } catch (error) {
      this.say(describe(error));
    }
  },
  /**
   * Approve or deny a machine's ask to join (#994). The card goes at once; the control plane's
   * control/joinDecided says the same to every other client. A refusal is said, and the card stays.
   */
  async decideJoin(this: Store, request: string, approve: boolean): Promise<void> {
    try {
      await this.link.call(approve ? "machines/approveJoin" : "machines/denyJoin", { request });
      this.joinRequests.value = withoutJoin(this.joinRequests.value, request);
    } catch (error) {
      this.say(describe(error));
    }
  },
};

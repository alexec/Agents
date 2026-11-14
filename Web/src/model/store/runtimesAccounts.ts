// Part of the Store (#5384): runtimesAccounts.
import { folderPath as hostedFolderPath, healthTally, personalServers } from "../hostedMCP";
import { batch } from "@preact/signals";
import type { HelperLimits, DiskThresholds, NotCommittedResponse, AccountProfile, RuntimeAccount, RuntimeSignInStep, RuntimeStatus, UUID, AutoPreview, AutoPreviewRequest, AutoSettings, ClientPermissionMode, Levels, ModelLevel, PermissionLevel, DirectoryListing, MCPHealthSnapshot, MCPToolsAnswer, ConnectorToolLevel, WorkflowHours, ClientPermissionSettings, PRCostComment, Connection } from "../../protocol/generated";
import { endedConnections, endedLine, hasEnded } from "../connectorSetup";
import { describe } from "../errors";
import { freeProjectName } from "../projectSettings";
import { folderKey } from "../groups";
import { sortedRuntimes } from "../runtimes";
import { Capability } from "../../protocol/capabilities.generated";
import type { Store } from "../store";

export const runtimesAccountsMethods = {
  /** The folder joins a project (#2317), through its own machine. Throws a refusal. */
  async setFolderProject(this: Store, host: string, folder: string, project: string): Promise<void> {
    const summary = await this.link.call("folders/setProject", { folder: folder as never, project }, host);
    this.upsertFolder(summary, host);
  },
  /** Remove from Project… (#3448): the folder leaves its project for a new one of its own, named after it. Throws a refusal. */
  async removeFolderFromProject(this: Store, host: string, folder: string, name: string): Promise<void> {
    const { projects } = await this.link.call("projects/list", {});
    const made = await this.link.call("projects/set", { name: freeProjectName(name, projects) });
    await this.setFolderProject(host, folder, made.id);
  },
  /** What in a folder's .agents Git ignores (#3448), read by its own machine. Throws a refusal. */
  notCommitted(this: Store, host: string, folder: string): Promise<NotCommittedResponse> {
    return this.link.call("folders/notCommitted", { folder: folder as never }, host);
  },
  /** What a folder's merged pull requests say of their cost (#2352). Throws a refusal. */
  async setFolderPRCostComment(this: Store, host: string, folder: string, prCostComment: PRCostComment): Promise<void> {
    const summary = await this.link.call("folders/setPRCostComment", { folder: folder as never, prCostComment }, host);
    this.upsertFolder(summary, host);
  },
  /** A project's working hours (#4821), for workflows' `hours: working`; undefined takes them out. Throws a refusal. */
  async setFolderWorkingHours(this: Store, host: string, folder: string, hours: WorkflowHours | undefined): Promise<void> {
    const summary = await this.link.call("folders/setWorkingHours", { folder: folder as never, ...(hours ? { hours } : {}) }, host);
    this.upsertFolder(summary, host);
  },
  /** A folder's helper limits and switches in `.agents/folder.json` (#64), from Project Settings (#3280). Throws a refusal. */
  async setFolderHelperLimits(this: Store, host: string, folder: string, limits: HelperLimits): Promise<void> {
    const summary = await this.link.call("folders/setHelperLimits", { folder: folder as never, limits }, host);
    this.upsertFolder(summary, host);
  },
  /** A folder's disk space lines (#195), from Folder Settings (#3280). Throws a refusal. */
  async setFolderDiskSpace(this: Store, host: string, folder: string, diskSpace: DiskThresholds): Promise<void> {
    const summary = await this.link.call("folders/setDiskSpace", { folder: folder as never, diskSpace }, host);
    this.upsertFolder(summary, host);
  },
  /** A folder pinned to the top of the sidebar, or not, as the window's Pin and Unpin. */
  async setFolderPinned(this: Store, host: string, folder: string, pinned: boolean): Promise<void> {
    const summary = await this.act("folders/setPinned", { folder: folder as never, pinned }, host);
    if (summary) this.upsertFolder(summary, host);
  },
  /** The folders at `path` on `host`, for choosing one as a folder (037). Throws a refusal. */
  browse(this: Store, host: string, path: string): Promise<DirectoryListing> {
    return this.link.call("files/browse", { path }, host);
  },
  /** What runs on a host, and what each runtime takes; asked once a connection. */
  async loadRuntimes(this: Store, host: string): Promise<void> {
    const macHost = this.macHostID.peek();
    // Auto's cells, for the pills' words on every runtime (#2658): the Mac's host keeps them.
    if (!this.autoMappings.peek()[macHost]) void this.loadAuto(macHost);
    const [runtimes, accounts, modes, sandbox, allowances, profiles, policy, passThrough, permissions] = await Promise.all([
      this.link.call("runtimes/list", {}, host).catch(() => null),
      this.link.call("runtimes/accounts", {}, host).catch(() => null),
      this.link.call("modes/remembered", {}, host).catch(() => null),
      // A host on an older build is not asked by the page: every runtime then follows its own.
      this.link.call("sandbox/state", {}, host).catch(() => null),
      this.link.call("runtimes/allowances", null, host).catch(() => null),
      // A host on an older build has no added accounts (#840).
      this.link.call("runtimes/accountProfiles", {}, host).catch(() => null),
      // A host on an older build follows no policy (#998).
      this.link.call("daemon/policyState", {}, host).catch(() => null),
      this.link.call("settings/passThrough", {}, host).catch(() => null),
      this.clientPermissions.value[macHost] ? Promise.resolve(null)
        : this.link.call("clientPermissions/state", {}, macHost).catch(() => null),
    ]);
    batch(() => {
      if (sandbox) {
        this.sandboxDefaults.value = { ...this.sandboxDefaults.value, [host]: sandbox.defaults };
        const { [host]: _, ...rest } = this.sandboxSetBy.value;
        this.sandboxSetBy.value = sandbox.setBy ? { ...rest, [host]: sandbox.setBy } : rest;
      }
      if (runtimes) this.runtimes.value = { ...this.runtimes.value, [host]: sortedRuntimes(runtimes) };
      if (allowances) this.runtimeAllowances.value = { ...this.runtimeAllowances.value, [host]: allowances };
      if (accounts) this.accounts.value = { ...this.accounts.value, [host]: accounts };
      if (profiles) this.accountProfiles.value = { ...this.accountProfiles.value, [host]: profiles };
      if (modes) this.rememberedModes.value = { ...this.rememberedModes.value, [host]: modes };
      if (policy) this.policyStates.value = { ...this.policyStates.value, [host]: policy };
      if (passThrough) this.passThrough.value = { ...this.passThrough.value, [host]: passThrough.names };
      if (permissions) {
        this.clientPermissions.value = { ...this.clientPermissions.value, [macHost]: permissions };
      }
    });
  },
  /** Set the Mac-wide permission choice, even when this chat belongs to a server. */
  /** Auto's settings and every cell on a host (#2658); an older host has none. */
  /** One load at a time per host: the Auto page asks on each draw until the cells come. */
  async loadAuto(this: Store, host: string): Promise<void> {
    if (this.autoLoading.has(host)) return;
    this.autoLoading.add(host);
    const { [host]: _, ...others } = this.autoProblems.value;
    this.autoProblems.value = others;
    let problem: string | undefined;
    try {
      const [settings, mappings] = await Promise.all([
        this.link.call("auto/state", {}, host).catch(() => null),
        this.link.call("auto/mappings", {}, host).catch((error: unknown) => {
          problem = describe(error);
          return null;
        }),
      ]);
      batch(() => {
        if (settings) this.autoSettings.value = { ...this.autoSettings.value, [host]: settings };
        if (mappings) this.autoMappings.value = { ...this.autoMappings.value, [host]: mappings };
        if (problem) this.autoProblems.value = { ...this.autoProblems.value, [host]: problem };
      });
    } finally {
      this.autoLoading.delete(host);
    }
  },
  /** Save Auto's settings on the Mac's host, which the Mac sends on to its machines (FR-017). */
  async setAutoSettings(this: Store, host: string, settings: AutoSettings): Promise<void> {
    const before = this.autoSettings.value[host];
    this.autoSettings.value = { ...this.autoSettings.value, [host]: settings };
    try {
      const saved = await this.link.call("auto/set", settings, host);
      this.autoSettings.value = { ...this.autoSettings.value, [host]: saved };
      await this.loadAuto(host);
    } catch (error) {
      if (before) this.autoSettings.value = { ...this.autoSettings.value, [host]: before };
      this.say(describe(error));
    }
  },
  /** What Auto would pick now for a folder and values, or null. */
  async autoPreview(this: Store, host: string, request: AutoPreviewRequest): Promise<AutoPreview | null> {
    return this.link.call("auto/preview", request, host).catch(() => null);
  },
  /** A running agent's model level or permission mode, on its own runtime (#2658). */
  async setLevels(this: Store, host: string, agentID: string, field: "model" | "permission", level: string): Promise<void> {
    const levels: Levels = field === "model" ? { model: level as ModelLevel } : { permission: level as PermissionLevel };
    try {
      await this.link.call("agents/setLevels", { agentID: agentID as UUID, levels }, host);
    } catch (error) {
      this.say(describe(error));
    }
  },
  /** A running agent's own answer to permission requests; none follows Settings (FR-019). */
  async setAgentClientPermission(this: Store, host: string, agentID: string, mode: ClientPermissionMode | undefined): Promise<void> {
    try {
      await this.link.call("agents/setClientPermission", { agentID: agentID as UUID, ...(mode ? { mode } : {}) }, host);
    } catch (error) {
      this.say(describe(error));
    }
  },
  async setClientPermissionMode(this: Store, runtimeID: string, mode: ClientPermissionSettings["cursor"]): Promise<void> {
    if (!["cursor", "grok", "opencode"].includes(runtimeID)) return;
    const host = this.macHostID.peek();
    const current = this.clientPermissions.value[host] ?? { cursor: "default", grok: "default", opencode: "default" };
    const settings = { ...current, [runtimeID]: mode } as ClientPermissionSettings;
    try {
      const saved = await this.link.call("clientPermissions/set", settings, host);
      this.clientPermissions.value = { ...this.clientPermissions.value, [host]: saved };
    } catch {
      this.problem.value = "That did not reach your Mac.";
    }
  },
  /** Keeps what a host's connections/list said: the ones that ended (#3407). */
  knowConnections(this: Store, host: string, list: readonly Connection[]): void {
    const ended = endedConnections(list);
    const had = this.endedConnections.value[host] ?? [];
    if (JSON.stringify(had) !== JSON.stringify(ended)) this.endedConnections.value = { ...this.endedConnections.value, [host]: ended };
  },
  /** Why the person's Connectors page warns (#587, #3407): one of their own connectors does not answer, or a connection
   * ended, on any host. Undefined when neither. */
  connectorsWarning(this: Store): string | undefined {
    const failing = this.hosts.value.map((h) => healthTally(personalServers(this.mcpHealthOf(h.id))))
      .filter((t) => t?.failing).map((t) => t!.words);
    const ended = endedLine(this.hosts.value.flatMap((h) => this.endedConnections.value[h.id] ?? []));
    const words = [...failing, ...(ended ? [ended] : [])];
    return words.length > 0 ? words.join(". ") : undefined;
  },
  /** Reads a host's connections, on a host that has them; a failed read keeps what it had. */
  async loadConnections(this: Store, host: string): Promise<void> {
    if (!this.has(host, Capability.connections1)) return;
    try {
      this.knowConnections(host, (await this.link.call("connections/list", {}, host)).connections);
    } catch { /* kept */ }
  },
  /** Each host's connections, and, on a host where one ended, the stored set-up of each project's Connectors folder there
   * (#3407): a slot stops working when its connection ends. A stored set-up is the host's last reading, so no provider is asked. */
  async refreshEndedConnections(this: Store, places: readonly { host: string; folder: string }[]): Promise<void> {
    const hosts = [...new Set(places.map((p) => p.host))].filter((h) => this.hostIsOnline(h));
    await Promise.all(hosts.map((h) => this.loadConnections(h)));
    const next: Record<string, Connection> = {};
    for (const { host, folder } of places) {
      if ((this.endedConnections.value[host] ?? []).length === 0 || !this.has(host, Capability.connectorsSetup1)) continue;
      const setup = await this.link.call("connectors/setup", { folder: hostedFolderPath(folder), reading: "stored" }, host).catch(() => null);
      if (setup?.connection && hasEnded(setup.connection)) next[`${host}|${folderKey(folder)}`] = setup.connection;
    }
    if (JSON.stringify(next) !== JSON.stringify(this.endedInFolders.value)) this.endedInFolders.value = next;
  },
  /** A host's MCP servers (#753); from a host too old to say, its hosted servers alone, as the page
   * showed them before. */
  mcpHealthOf(this: Store, host: string): MCPHealthSnapshot | undefined {
    const health = this.mcpHealth.value[host];
    if (health) return health;
    const hosted = this.hostedMCP.value[host];
    if (!hosted) return undefined;
    return {
      servers: hosted.servers.map((live) => ({
        name: live.name, ...(live.folder != null ? { folder: live.folder } : {}),
        transport: "stdio" as const, hosted: true, live, check: "unchecked" as const,
      })),
      problems: [], at: hosted.at,
    };
  },
  /** Check Now on the person's own servers (no folder) or a folder's (#753). */
  async checkMCPHealth(this: Store, host: string, folder?: string): Promise<void> {
    const request = folder === undefined ? {} : { folder: hostedFolderPath(folder) };
    const snapshot = await this.link.call("mcp/health/check", request, host).catch(() => null);
    if (snapshot) this.mcpHealth.value = { ...this.mcpHealth.value, [host]: snapshot };
  },
  /**
   * Takes one connector out of its mcp.json (#2154), the person's own (no folder) or a folder's,
   * one the app added or one written by hand, then checks the rest again. Its secrets stay.
   * Undefined when it went, else why not.
   */
  async removeConnector(this: Store, host: string, name: string, folder?: string): Promise<string | undefined> {
    const destination = folder === undefined ? { kind: "personal" } : { kind: "folder", folder: hostedFolderPath(folder) };
    const why = await this.link.call("mcp/remove", { destination: destination as never, name }, host)
      .then(() => undefined, (error: unknown) => describe(error));
    if (why === undefined) await this.checkMCPHealth(host, folder);
    return why;
  },
  /** A connector's tools with Allow, Ask or Off for each (#4099); its refusal's words when the host refuses. */
  async connectorTools(this: Store, host: string, name: string, folder?: string): Promise<MCPToolsAnswer | string> {
    const destination = folder === undefined ? { kind: "personal" } : { kind: "folder", folder: hostedFolderPath(folder) };
    return this.link.call("mcp/tools", { destination: destination as never, name }, host)
      .then((answer) => answer, (error: unknown) => describe(error));
  },
  /** One tool's level, or with no tool the switch for every tool that writes; no level clears it (#4099). */
  async setConnectorToolLevel(this: Store, host: string, name: string, tool: string | undefined, level: ConnectorToolLevel | undefined,
    folder?: string): Promise<MCPToolsAnswer | string> {
    const destination = folder === undefined ? { kind: "personal" } : { kind: "folder", folder: hostedFolderPath(folder) };
    return this.link.call("mcp/setToolLevel", { destination: destination as never, name, ...(tool === undefined ? {} : { tool }), ...(level === undefined ? {} : { level }) }, host)
      .then((answer) => answer, (error: unknown) => describe(error));
  },
  async markRuntimeAvailable(this: Store, host: string, credentialKey: string): Promise<void> {
    const allowances = await this.link.call("runtimes/markAvailable", { credentialKey }, host).catch(() => null);
    if (allowances) this.runtimeAllowances.value = { ...this.runtimeAllowances.value, [host]: allowances };
  },
  /** The accounts of one of a host's runtimes: the ones added (#840), in the order they were added, then the organisation's (#999). */
  addedAccounts(this: Store, host: string, runtimeID: string): AccountProfile[] {
    return (this.accountProfiles.value[host] ?? []).filter((a) => a.runtimeID === runtimeID);
  },
  /** Add an account to a runtime (#840). Throws the host's refusal. */
  async addAccount(this: Store, host: string, runtimeID: string, name: string): Promise<AccountProfile> {
    const added = await this.link.call("runtimes/addAccount", { runtimeID, name }, host);
    const rest = (this.accountProfiles.value[host] ?? []).filter((a) => a.id !== added.id);
    this.accountProfiles.value = { ...this.accountProfiles.value, [host]: [...rest, added] };
    void this.reloadAllowances(host);
    return added;
  },
  /** Sign a server's Claude or Codex in (#3349): the link, and the code to type there or the want of one back. Throws the host's refusal. */
  signInStart(this: Store, host: string, runtimeID: string): Promise<RuntimeSignInStep> {
    return this.link.call("runtimes/signInStart", { runtimeID }, host);
  },
  /** The end of a sign-in: the code the page gave, or cancel. Throws the host's refusal, such as a code it did not take. */
  async signInFinish(this: Store, host: string, signInID: string, finish: { code?: string; cancel?: boolean }): Promise<void> {
    this.noteRuntime(host, await this.link.call("runtimes/signInFinish", { signInID, ...finish }, host));
  },
  /** Sign a server's Claude or Codex in with an API key (#3349). Throws the host's refusal. */
  async signInKey(this: Store, host: string, runtimeID: string, key: string): Promise<void> {
    this.noteRuntime(host, await this.link.call("runtimes/signInKey", { runtimeID, key }, host));
  },
  /**
   * Update on a machine's runtime (#4174, as the Remote's #4035): the machine installs the app's newer copy over the one it
   * has. The page is not told runtime/changed, so it reads the machine's list again until the install is over.
   */
  async updateRuntime(this: Store, host: string, runtimeID: string): Promise<void> {
    const status = await this.act("runtimes/install", { runtimeID }, host);
    if (!status) return;
    this.noteRuntime(host, status);
    for (let tries = 0; tries < 200; tries++) {
      const now = (this.runtimes.peek()[host] ?? []).find((r) => r.runtime.id === runtimeID);
      if (!now || !("installing" in now.availability)) return;
      await new Promise((resolve) => setTimeout(resolve, 3_000));
      const list = await this.link.call("runtimes/list", {}, host).catch(() => null);
      if (list) this.runtimes.value = { ...this.runtimes.value, [host]: sortedRuntimes(list) };
    }
  },
  /** A host's runtimes read again alone, for a page waiting on an install or a sign-in made elsewhere (#5054). */
  async reloadRuntimeList(this: Store, host: string): Promise<void> {
    const list = await this.link.call("runtimes/list", {}, host).catch(() => null);
    if (list) this.runtimes.value = { ...this.runtimes.value, [host]: sortedRuntimes(list) };
  },
  /** Whether a host's github connector is connected (#5054); undefined when it could not be read. */
  async githubConnected(this: Store, host: string): Promise<boolean | undefined> {
    if (!this.has(host, Capability.connections1)) return undefined;
    try {
      const { connections } = await this.link.call("connections/list", {}, host);
      this.knowConnections(host, connections);
      return connections.some((c) => c.provider === "github" && c.state === "connected");
    } catch {
      return undefined;
    }
  },
  /** One runtime's status, in place of the one the page had. */
  noteRuntime(this: Store, host: string, status: RuntimeStatus): void {
    const list = this.runtimes.value[host] ?? [];
    this.runtimes.value = { ...this.runtimes.value, [host]: list.map((r) => (r.runtime.id === status.runtime.id ? status : r)) };
    // Its allowance row said it could not be used without a sign-in.
    void this.reloadAllowances(host);
  },
  /** Remove an added account: its sessions stop, and its folder goes (#840). */
  async removeAccount(this: Store, host: string, account: AccountProfile): Promise<void> {
    await this.link.call("runtimes/removeAccount", { runtimeID: account.runtimeID, accountID: account.id }, host);
    this.accountProfiles.value = {
      ...this.accountProfiles.value,
      [host]: (this.accountProfiles.value[host] ?? []).filter((a) => a.id !== account.id),
    };
    void this.reloadAllowances(host);
  },
  /** Reaches the Model By (#999): a runtime's account for new sessions, "default" for its own sign-in. Throws the host's refusal. */
  async setDefaultAccount(this: Store, host: string, runtimeID: string, accountID: string): Promise<void> {
    await this.link.call("runtimes/setDefaultAccount", { runtimeID, accountID }, host);
    const profiles = await this.link.call("runtimes/accountProfiles", {}, host).catch(() => null);
    if (profiles) this.accountProfiles.value = { ...this.accountProfiles.value, [host]: profiles };
  },
  async reloadAllowances(this: Store, host: string): Promise<void> {
    const allowances = await this.link.call("runtimes/allowances", null, host).catch(() => null);
    if (allowances) this.runtimeAllowances.value = { ...this.runtimeAllowances.value, [host]: allowances };
  },
  account(this: Store, host: string, runtimeID: string): RuntimeAccount | undefined {
    return (this.accounts.value[host] ?? []).find((a) => a.runtimeID === runtimeID);
  },
};

// Every section of Settings (#2020): its group, its place in the group, and the component that draws it. A new
// section is a file of its own and one line here, sorted by name, so two features that each add one touch
// different lines. SettingsPage draws each group's sections by `order`.
import type { ComponentType } from "preact";
import type { Store } from "../../model/store";
import { ChannelsSection } from "../ChannelLinks";
import { GroupsSection } from "../Groups";
import { BotsSection, PeopleSection } from "../People";
import { ProvidersSection } from "../Providers";
import { SignInSection, SignInsSection } from "../SignInSection";
import { AgentRuntimesSection } from "./AgentRuntimes";
import { AgentsPolicySection } from "./AgentsPolicy";
import { BackupsSection, ServerBackupsSection } from "./Backups";
import { BrowserSection } from "./Browser";
import { ConnectAnotherSection } from "./ConnectAnother";
import { ControlOverviewSection } from "./ControlOverview";
import { DesktopControlSection } from "./DesktopControl";
import { ForgeLoginsSection } from "./ForgeLogins";
import { GitAccessSection } from "./GitAccess";
import { VersionsSection } from "./Machines";
import { NotificationsSection } from "./Notifications";
import { PolicySection } from "./Policy";
import { ProcessesSection } from "./Processes";
import { RecoveryKeySection } from "./RecoveryKey";
import { SidebarGroupsSection } from "./SidebarGroups";
import { SleepSection } from "./Sleep";
import { PersonasConfigSection, SkillsConfigSection, WorkflowsConfigSection } from "../AgentConfigEditor";

/** Settings' groups by subject (#2157, was by scope #1759): this browser, what agents may do (#2957), the machines
 * that run agents, and what the control plane keeps (the person's sign-ins first). */
export type SettingsScope = "thisApp" | "agents" | "machines" | "agentConfiguration" | "controlPlane";

export interface SettingsSection {
  name: string;
  scope: SettingsScope;
  /** Its place in its group: the lowest first. */
  order: number;
  Section: ComponentType<{ store: Store; down: boolean }>;
  /** Whether it is shown at all; always when left out. */
  shows?: (store: Store) => boolean;
}

export const settingsSections: readonly SettingsSection[] = [
  // Auto's order and Mappings (#2658), kept on the Mac's host.
  { name: "agentRuntimes", scope: "machines", order: 50, Section: AgentRuntimesSection },
  // Your layer of what agents may do (#2957): the limits of Spending, Notifications and the archive switch moved here.
  { name: "agentsPolicy", scope: "agents", order: 10, Section: AgentsPolicySection },
  { name: "backups", scope: "machines", order: 30, Section: BackupsSection },
  // The bots that run the team's workflows, apart from the people (#2132): an admin's.
  { name: "bots", scope: "controlPlane", order: 15, Section: BotsSection, shows: (store) => store.person.value?.role === "admin" },
  // The machine's browser that agents drive (#3535): its sites with sign-ins, Clear, and its download.
  { name: "browser", scope: "machines", order: 55, Section: BrowserSection },
  // Channel identities linked to people (#1762).
  { name: "channels", scope: "controlPlane", order: 30, Section: ChannelsSection },
  // Connect to Another… on the page this Mac serves (#4257): the window on this Mac does it.
  { name: "connectAnother", scope: "controlPlane", order: 55, Section: ConnectAnotherSection, shows: (store) => store.canConnectAnother.value },
  // Serve Agents to browsers on this Mac and Restart, on the page this Mac serves (#4252), first as in the window.
  { name: "controlOverview", scope: "controlPlane", order: 1, Section: ControlOverviewSection, shows: (store) => store.canControlThisMac.value },
  // The off-by-default switch for drive_screen (#3004, US2).
  { name: "desktopControl", scope: "machines", order: 35, Section: DesktopControlSection },
  // Your GitHub, GitLab, Linear, Jira, Forgejo, Bitbucket and Azure DevOps logins, for the Team section and "An agent is on it" (#2951, #3160).
  { name: "forgeLogins", scope: "controlPlane", order: 7, Section: ForgeLoginsSection },
  { name: "gitAccess", scope: "machines", order: 10, Section: GitAccessSection },
  // Groups own machine providers (#1761).
  { name: "groups", scope: "controlPlane", order: 20, Section: GroupsSection },
  // Whether this page shows notices (#2860, #1486); how many agents may send is in Agents ▸ Policy (#2957).
  { name: "notifications", scope: "thisApp", order: 40, Section: NotificationsSection },
  // Who belongs to the control plane, and their machines and clients (#994).
  { name: "people", scope: "controlPlane", order: 10, Section: PeopleSection },
  { name: "personas", scope: "agentConfiguration", order: 20, Section: PersonasConfigSection },
  // Organisation Policy (#2957, was Policy): the organisation's rules, read only, and the kill switch for an admin (#998).
  { name: "policy", scope: "controlPlane", order: 45, Section: PolicySection },
  // What runs on each machine, with its CPU and memory (#3453).
  { name: "processes", scope: "machines", order: 45, Section: ProcessesSection },
  { name: "providers", scope: "controlPlane", order: 50, Section: ProvidersSection },
  // The lock's recovery key (#4299): Make Recovery Key after the sidebar's card was skipped or before it shows.
  { name: "recoveryKey", scope: "machines", order: 5, Section: RecoveryKeySection },
  { name: "serverBackups", scope: "machines", order: 40, Section: ServerBackupsSection },
  // Kept on the Mac's host, the same on every client (#1033, #2079); its subject is the app (#2157).
  { name: "sidebar", scope: "thisApp", order: 20, Section: SidebarGroupsSection },
  // Which providers people sign in with (#995): an admin's.
  { name: "signInProviders", scope: "controlPlane", order: 40, Section: SignInSection, shows: (store) => store.person.value?.role === "admin" },
  // How you sign in on your Macs, iPhones and iPads (#995).
  { name: "signIns", scope: "controlPlane", order: 5, Section: SignInsSection },
  { name: "skills", scope: "agentConfiguration", order: 10, Section: SkillsConfigSection },
  // The Mac's runtime pickers (#4066): Keep ready for a reply and Keep runtimes with background processes.
  { name: "sleep", scope: "machines", order: 37, Section: SleepSection },
  // The control plane's version (#1748); the machines it lists are in the sidebar (#3975).
  { name: "version", scope: "controlPlane", order: 60, Section: VersionsSection },
  { name: "workflows", scope: "agentConfiguration", order: 30, Section: WorkflowsConfigSection },
];

/** One group's sections, in their order, less any not shown now. */
export function sectionsIn(scope: SettingsScope, store: Store): SettingsSection[] {
  return settingsSections.filter((s) => s.scope === scope && (s.shows?.(store) ?? true))
    .sort((a, b) => a.order - b.order);
}

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
import { SecretsSection } from "../UserScope";
import { AgentRuntimesSection } from "./AgentRuntimes";
import { BackupsSection, ServerBackupsSection } from "./Backups";
import { DesktopControlSection } from "./DesktopControl";
import { FinishedChatsSection } from "./FinishedChats";
import { GitAccessSection } from "./GitAccess";
import { VersionsSection } from "./Machines";
import { NotificationsSection } from "./Notifications";
import { PolicySection } from "./Policy";
import { SidebarGroupsSection } from "./SidebarGroups";
import { PersonasConfigSection, SkillsConfigSection, WorkflowsConfigSection } from "../AgentConfigEditor";

/** Settings' groups by subject (#2157, was by scope #1759): this browser, the machines that run agents, and
 * what the control plane keeps (the person's sign-ins first). */
export type SettingsScope = "thisApp" | "machines" | "agentConfiguration" | "controlPlane";

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
  { name: "backups", scope: "machines", order: 30, Section: BackupsSection },
  // The bots that run the team's workflows, apart from the people (#2132): an admin's.
  { name: "bots", scope: "controlPlane", order: 15, Section: BotsSection, shows: (store) => store.person.value?.role === "admin" },
  // Channel identities linked to people (#1762).
  { name: "channels", scope: "controlPlane", order: 30, Section: ChannelsSection },
  // The off-by-default switch for drive_screen (#3004, US2).
  { name: "desktopControl", scope: "machines", order: 35, Section: DesktopControlSection },
  { name: "finishedChats", scope: "thisApp", order: 30, Section: FinishedChatsSection },
  { name: "gitAccess", scope: "machines", order: 10, Section: GitAccessSection },
  // Groups own machine providers (#1761).
  { name: "groups", scope: "controlPlane", order: 20, Section: GroupsSection },
  { name: "machines", scope: "machines", order: 20, Section: VersionsSection },
  // How many notices agents may send you (#2805), kept on the Mac's host, the same on every client;
  // headed "What agents tell you", as the window's and the Remote's, with a hint that they are not this browser's (#2895).
  { name: "notifications", scope: "thisApp", order: 40, Section: NotificationsSection },
  // Who belongs to the control plane, and their machines and clients (#994).
  { name: "people", scope: "controlPlane", order: 10, Section: PeopleSection },
  { name: "personas", scope: "agentConfiguration", order: 20, Section: PersonasConfigSection },
  // The organisation's rules, read only, and the kill switch for an admin (#998).
  { name: "policy", scope: "controlPlane", order: 45, Section: PolicySection },
  { name: "providers", scope: "controlPlane", order: 50, Section: ProvidersSection },
  // The secrets the control plane keeps for you and sends to each machine of yours (#1760, #2157).
  { name: "secrets", scope: "machines", order: 60, Section: SecretsSection },
  { name: "serverBackups", scope: "machines", order: 40, Section: ServerBackupsSection },
  // Kept on the Mac's host, the same on every client (#1033, #2079); its subject is the app (#2157).
  { name: "sidebar", scope: "thisApp", order: 20, Section: SidebarGroupsSection },
  // Which providers people sign in with (#995): an admin's.
  { name: "signInProviders", scope: "controlPlane", order: 40, Section: SignInSection, shows: (store) => store.person.value?.role === "admin" },
  // How you sign in on your Macs, iPhones and iPads (#995).
  { name: "signIns", scope: "controlPlane", order: 5, Section: SignInsSection },
  { name: "skills", scope: "agentConfiguration", order: 10, Section: SkillsConfigSection },
  { name: "workflows", scope: "agentConfiguration", order: 30, Section: WorkflowsConfigSection },
];

/** One group's sections, in their order, less any not shown now. */
export function sectionsIn(scope: SettingsScope, store: Store): SettingsSection[] {
  return settingsSections.filter((s) => s.scope === scope && (s.shows?.(store) ?? true))
    .sort((a, b) => a.order - b.order);
}

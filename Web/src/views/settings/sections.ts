// Every section of Settings (#2020): its group, its place in the group, and the component that draws it. A new
// section is a file of its own and one line here, sorted by name, so two features that each add one touch
// different lines. SettingsPage draws each group's sections by `order`.
import type { ComponentType } from "preact";
import type { Store } from "../../model/store";
import { ChannelsSection } from "../ChannelLinks";
import { GroupsSection } from "../Groups";
import { PeopleSection } from "../People";
import { ProvidersSection } from "../Providers";
import { SignInSection, SignInsSection } from "../SignInSection";
import { UserScopeSection } from "../UserScope";
import { AppearanceSection } from "./Appearance";
import { BackupsSection, ServerBackupsSection } from "./Backups";
import { FinishedChatsSection } from "./FinishedChats";
import { GitAccessSection } from "./GitAccess";
import { VersionsSection } from "./Machines";
import { SidebarGroupsSection } from "./SidebarGroups";

/** Settings' groups by subject (#2157, was by scope #1759): this browser, the machines that run agents, and
 * what the control plane keeps (the person's sign-ins first). */
export type SettingsScope = "thisApp" | "machines" | "controlPlane";

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
  { name: "appearance", scope: "thisApp", order: 10, Section: AppearanceSection },
  { name: "backups", scope: "machines", order: 30, Section: BackupsSection },
  // Channel identities linked to people (#1762).
  { name: "channels", scope: "controlPlane", order: 30, Section: ChannelsSection },
  { name: "finishedChats", scope: "thisApp", order: 30, Section: FinishedChatsSection },
  { name: "gitAccess", scope: "machines", order: 10, Section: GitAccessSection },
  // Groups own workspace providers (#1761).
  { name: "groups", scope: "controlPlane", order: 20, Section: GroupsSection },
  { name: "machines", scope: "machines", order: 20, Section: VersionsSection },
  // Who belongs to the control plane, and their machines and clients (#994).
  { name: "people", scope: "controlPlane", order: 10, Section: PeopleSection },
  { name: "providers", scope: "controlPlane", order: 50, Section: ProvidersSection },
  { name: "serverBackups", scope: "machines", order: 40, Section: ServerBackupsSection },
  // Kept on the Mac's host, the same on every client (#1033, #2079); its subject is the app (#2157).
  { name: "sidebar", scope: "thisApp", order: 20, Section: SidebarGroupsSection },
  // Which providers people sign in with (#995): an admin's.
  { name: "signInProviders", scope: "controlPlane", order: 40, Section: SignInSection, shows: (store) => store.person.value?.role === "admin" },
  // How you sign in on your Macs, iPhones and iPads (#995).
  { name: "signIns", scope: "controlPlane", order: 5, Section: SignInsSection },
  // The settings and secrets the control plane keeps for you (#1760).
  { name: "userScope", scope: "machines", order: 50, Section: UserScopeSection },
];

/** One group's sections, in their order, less any not shown now. */
export function sectionsIn(scope: SettingsScope, store: Store): SettingsSection[] {
  return settingsSections.filter((s) => s.scope === scope && (s.shows?.(store) ?? true))
    .sort((a, b) => a.order - b.order);
}

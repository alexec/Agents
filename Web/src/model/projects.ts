// A folder's Project (#2317): the words of ProjectWords in Packages/AgentsKit
// (Model/Project.swift), the same on the Mac, the Remote and the web page.
import type { ConnectorSetup, ConnectorSlot, Project, ProjectSlot } from "../protocol/generated";

export const projectWords = {
  title: "Project",
  newProject: "New Project…",
  rename: "Rename Project…",
  namePrompt: "Project name",
  explanation: "Folders in one project share its tools and its reports, on every machine. "
    + "The project is saved in .agents/folder.json, so a clone you commit it in joins the same project.",
  noControlPlane: "Connect to a control plane to choose a project.",
  useForProject: "Use for the Whole Project",
  useFolderOwn: "Use Each Folder's Own",
} as const;

/** On a Connectors page whose folder is in a project (#2669): whose the slots are, and who may change them. */
export function slotsOwner(name: string): string {
  return `Tasks, Code review and CI are the project's (${name}), the same in every folder of it. Only its owner or an admin changes them.`;
}

/** A slot the project sets. */
export function setByProject(name: string): string {
  return `Set by the project ${name}.`;
}

/** One slot's row in the project's card: what fills it, and whose it is. */
export function slotLine(slot: ConnectorSlot, name: string): string {
  const what = [slot.choice, slot.repository].filter((p) => p).join(" · ");
  const skipped = slot.state === "skipped";
  if (slot.fromProject) return skipped ? `Skipped in every folder of ${name}.` : `${what}, for every folder of ${name}.`;
  if (skipped) return "Skipped in this folder only.";
  return slot.repository == null ? "This folder has no GitHub or GitLab remote." : `${what}, this folder's own.`;
}

/** The folder's own slot, as the project's for every folder. */
export function projectSlotFrom(setup: ConnectorSetup, slot: ConnectorSlot): ProjectSlot | undefined {
  if (slot.state === "skipped") return { slot: slot.slot, skipped: true };
  const repository = slot.repository ?? setup.repository;
  if (repository == null) return undefined;
  return { slot: slot.slot, forge: setup.forge ?? "github", repository, site: setup.site ?? "github.com" };
}

/** A folder whose id the control plane has not adopted yet. */
export function unknownProject(id: string): string {
  return `Not on the control plane yet (${id})`;
}

/** The project a folder is in, by its id, from the list. */
export function projectName(id: string | undefined, projects: readonly Project[]): string | undefined {
  if (id === undefined) return undefined;
  return projects.find((p) => p.id === id)?.name;
}

/** Whether a project of this name, in any case, is there already, other than `except`. */
export function projectTaken(name: string, projects: readonly Project[], except?: string): boolean {
  const wanted = name.trim().toLowerCase();
  return projects.some((p) => p.id !== except && p.name.toLowerCase() === wanted);
}

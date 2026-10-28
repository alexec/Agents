// A folder's Project (#2317): the words of ProjectWords in Packages/AgentsKit
// (Model/Project.swift), the same on the Mac, the Remote and the web page.
import { CallFailed, describe, methodNotFound } from "./errors";
import type { ConnectorSetup, ConnectorSlot, PersonRow, Project, ProjectFolder, ProjectSlot } from "../protocol/generated";

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
  // The Add Folder sheet's first choice (#2671), what a solo person keeps.
  ownProject: "Its Own Project",
  addNote: "Its own project is a new one of the folder's name, or the one its .agents/folder.json names. "
    + "Pick another to share that project's tools and reports.",
  remove: "Remove Project",
  tryAgain: "Try Again",
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

/**
 * The projects could not be read (#2756), kept apart from a list with none: what went wrong,
 * said next to Try Again. Undefined for an older control plane, which has no projects.
 */
export function projectsNotRead(error: unknown): string | undefined {
  if (error instanceof CallFailed && error.code === methodNotFound) return undefined;
  return `Couldn't read the projects. ${describe(error)}`;
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

// Console ▸ Projects (#2671): every project in the organisation, its owner and its folders on each machine.

/** Under the Console's table. */
export const projectsFoot = "A project is what people work on. Each folder names its project in .agents/folder.json, "
  + "so its clones on other machines join the same one. The folders are as each machine last said them. "
  + "A project with folders in it cannot be removed: move them to another project first.";

/** The owner's name, from the people list; the id when the person is not on it. */
export function projectOwner(owner: string, people: readonly PersonRow[]): string {
  if (!owner) return "Nobody";
  return people.find((p) => p.id === owner)?.name ?? owner;
}

/** A project's folders, by machine and then by name, each with the machine's name. */
export function projectFolders(project: Project, machineName: (id: string) => string): { machine: string; folder: ProjectFolder }[] {
  return project.folders
    .map((folder) => ({ machine: machineName(folder.machine), folder }))
    .sort((a, b) => a.machine.localeCompare(b.machine) || a.folder.name.localeCompare(b.folder.name));
}

/** Why Remove is off, or null when it may be done. */
export function removeRefusal(project: Project): string | null {
  if (!project.mayChange) return "Only its owner or an admin removes a project.";
  if (project.folders.length > 0) return "A folder is still in it. Move its folders to another project first.";
  return null;
}

/** What Remove asks. */
export function removeQuestion(project: Project): string {
  return `Remove the project ${project.name}? A folder that names it later brings it back.`;
}

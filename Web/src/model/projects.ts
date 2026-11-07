// A folder's Project (#2317): the words of ProjectWords in Packages/AgentsKit
// (Model/Project.swift), the same on the Mac, the Remote and the web page.
import { CallFailed, describe, methodNotFound } from "./errors";
import type { ConnectorSetup, ConnectorSlot, PersonRow, Project, ProjectBoard, ProjectFolder, ProjectSlot } from "../protocol/generated";

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

/** A project's boards (#3282), on the Connectors page and in Work's Board menu, as ProjectBoardWords on the window. */
export const boardWords = {
  heading: "Boards",
  note: "A board is a GitHub Projects board, a Jira board, a Linear team or a GitLab group board. "
    + "Work ▸ Issues and Features can show one board.",
  none: "No boards. Work shows every issue of the project.",
  onlyOwner: "Only the project's owner or an admin can change its boards.",
  namePrompt: "Name",
  addressPrompt: "https://github.com/orgs/acme/projects/7",
  add: "Add Board",
  remove: "Remove",
} as const;

/** A board's forge, in words, after its name; empty for one the control plane has not read. */
export function boardForge(board: ProjectBoard): string {
  switch (board.forge) {
    case "github": return "GitHub Projects";
    case "atlassian": return "Jira";
    case "linear": return "Linear team";
    case "gitlab": return "GitLab";
    default: return "";
  }
}

/** What projects/setBoards takes of each board: its name and its address. The control plane reads the rest. */
const sent = (boards: readonly ProjectBoard[]): ProjectBoard[] => boards.map(({ name, url }) => ({ name, url }));

/** The boards with one more at the end, its name and address trimmed; undefined when either is empty. */
export function boardsWith(boards: readonly ProjectBoard[], name: string, url: string): ProjectBoard[] | undefined {
  const n = name.trim(), u = url.trim();
  if (!n || !u) return undefined;
  return [...sent(boards), { name: n, url: u }];
}

/** The boards without the one at `url`. */
export function boardsWithout(boards: readonly ProjectBoard[], url: string): ProjectBoard[] {
  return sent(boards.filter((b) => b.url !== url));
}

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
  return slot.repository == null ? "This folder has no GitHub, GitLab or Forgejo remote." : `${what}, this folder's own.`;
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

/**
 * New Session's projects (#3279), the rule of NewSessionProject in Packages/AgentsKit, the same
 * on the Mac and the Remote: the folders in the sidebar's order, as projects. A folder that names
 * no project is a project of its own, and a project is named by its first folder, so a project
 * with one folder looks as that folder does today.
 */
export interface NewSessionProject<T> { id: string; name: string; folders: T[] }

export function newSessionProjectID(host: string, folder: { folder: { folder: string }; project?: string }): string {
  return folder.project ? folder.project : `folder:${host}|${folder.folder.folder}`;
}

export function newSessionProjects<T extends { host: { id: string }; folder: { name: string; project?: string; folder: { folder: string } } }>(
  ordered: readonly T[]): NewSessionProject<T>[] {
  const projects = new Map<string, NewSessionProject<T>>();
  for (const row of ordered) {
    const id = newSessionProjectID(row.host.id, row.folder);
    const project = projects.get(id);
    if (project) project.folders.push(row);
    else projects.set(id, { id, name: row.folder.name, folders: [row] });
  }
  return [...projects.values()];
}

/**
 * The folder a picked project starts in: the one last used in it, else the first. The web page is
 * no machine of the project's, so "this machine" is the machine last used (#3273).
 */
export function projectFolder<T>(project: NewSessionProject<T>, remembered: ((row: T) => boolean) | undefined): T | undefined {
  return (remembered && project.folders.find(remembered)) ?? project.folders[0];
}

const projectFoldersKey = "agents.newSession.projectFolders";

/** The folder last used in each project (`host|folder`), kept in localStorage as the window keeps it in defaults. */
export function rememberedProjectFolders(storage: Storage | undefined): Record<string, string> {
  try {
    const stored = JSON.parse(storage?.getItem(projectFoldersKey) ?? "null");
    return stored && typeof stored === "object" ? stored as Record<string, string> : {};
  } catch {
    return {};
  }
}

export function rememberProjectFolder(storage: Storage | undefined, project: string, folder: string): void {
  try {
    const kept = rememberedProjectFolders(storage);
    if (kept[project] === folder) return;
    storage?.setItem(projectFoldersKey, JSON.stringify({ ...kept, [project]: folder }));
  } catch {
    // A private window may refuse to store; the first folder stands in.
  }
}

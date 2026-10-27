// A folder's Project (#2317): the words of ProjectWords in Packages/AgentsKit
// (Model/Project.swift), the same on the Mac, the Remote and the web page.
import type { Project } from "../protocol/generated";

export const projectWords = {
  title: "Project",
  newProject: "New Project…",
  rename: "Rename Project…",
  namePrompt: "Project name",
  explanation: "Folders in one project share its tools and its reports, on every machine. "
    + "The project is saved in .agents/folder.json, so a clone you commit it in joins the same project.",
  noControlPlane: "Connect to a control plane to choose a project.",
} as const;

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

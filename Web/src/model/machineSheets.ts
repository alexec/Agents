// Update…, Choose Folders… and Link to Provider… on a machine's row (#4122), as the window's
// ControlAddServerSheet (updating), ChooseFoldersSheet and LinkWorkspaceSheet: which the row offers,
// and what each says.
import type { ControlMachine, FoundFolder, MachineInfo, ProviderSummary } from "../protocol/generated";
import { folderPathOf } from "./projectSettings";

/** Which of the three a row's menu has: Update… for one that needs it, Choose Folders… (online only) and
 * Link to Provider… for a registered machine. This Mac has none. */
export function machineSheets(host: ControlMachine, macID: string, online: boolean): { update: boolean; folders: boolean; foldersReady: boolean; link: boolean } {
  if (host.id === macID) return { update: false, folders: false, foldersReady: false, link: false };
  return { update: host.state === "needsUpdate", folders: true, foldersReady: online, link: !host.workspace };
}

export const updateWords = {
  title: (name: string) => `Update ${name}`,
  note: (name: string) => `The machine ${name} runs on, as the control plane reaches it over ssh. The control plane checks it is ${name}, copies its version of Agent Loops there and starts it again. Its agents and folders stay.`,
  trustNote: (fingerprint: string) => `This machine’s host key is new to the control plane: ${fingerprint}. Update only if this is the key the machine shows (ssh-keygen -lf on its host key).`,
  updating: "Updating Agent Loops over ssh… This takes a minute or two.",
  updated: (name: string) => `Updated ${name}. It starts again with this control plane’s version.`,
  noDestination: "Give the ssh destination.",
};

export const chooseFoldersWords = {
  title: "Choose Folders",
  intro: (name: string, paths: readonly string[]) => paths.length === 0
    ? `Add folders on ${name} as folders.` : `Folders found on ${name}. Tick the ones to add.`,
  looking: (paths: readonly string[]) => `Looking in ${paths.join(", ")}…`,
  none: (paths: readonly string[]) => `No git repositories directly inside ${paths.join(", ")}.`,
  placeholder: (name: string) => `A folder on ${name}, such as ~/work/app`,
  noSuch: (typed: string, name: string) => `There is no folder ${typed} on ${name}.`,
  cantAsk: (name: string, why: string) => `${name} could not be asked for its folders: ${why}`,
  cantAskAbout: (name: string, typed: string, why: string) => `${name} could not be asked about ${typed}: ${why}`,
};

/** A found folder's path on its machine, which is also its key in the list. */
export function foundPath(found: FoundFolder): string {
  return folderPathOf(found.folder);
}

/** Its name: the path's last part. */
export function foundName(found: FoundFolder): string {
  return foundPath(found).split("/").pop() || foundPath(found);
}

/** What its row says after the path: already a folder, or not a git repository. */
export function foundNote(found: FoundFolder): string {
  if (found.isFolder) return "· already a folder";
  if (!found.isRepository) return "· not a git repository";
  return "";
}

/** Add's title, by how many are ticked. */
export function addFoldersTitle(ticked: number): string {
  return ticked === 0 ? "Add Folders" : ticked === 1 ? "Add 1 Folder" : `Add ${ticked} Folders`;
}

/** What was not added, by name, with why. */
export function notAddedLine(failed: Readonly<Record<string, string>>): string {
  const name = (folder: string) => folderPathOf(folder).split("/").pop() || folder;
  return "Not added: " + Object.entries(failed).map(([folder, why]) => `${name(folder)} (${why})`).sort().join("; ");
}

/** A workspace Link to Provider… offers: its key, and the machine it is linked to already, which it can't take. */
export interface LinkChoice {
  key: string;
  provider: string;
  workspace: MachineInfo;
  linkedTo?: string | undefined;
}

/** Link to Provider…' list: each provider with its workspaces, a workspace another machine has named and not chosen. */
export function linkChoices(providers: readonly ProviderSummary[], hosts: readonly ControlMachine[]): { provider: ProviderSummary; workspaces: LinkChoice[] }[] {
  return providers.filter((p) => p.workspaces.length > 0).map((provider) => ({
    provider,
    workspaces: provider.workspaces.map((workspace) => ({
      key: `${provider.id}/${workspace.id}`, provider: provider.id, workspace,
      linkedTo: workspace.host ? hosts.find((h) => h.id === workspace.host)?.name : undefined,
    })),
  }));
}

/** A workspace's grey words in the list: the machine it is linked to, or its state. */
export function linkChoiceLine(choice: LinkChoice): string {
  if (choice.linkedTo) return `linked to ${choice.linkedTo}`;
  const state = choice.workspace.state;
  return state.charAt(0).toUpperCase() + state.slice(1);
}

// The runtime's own conversations that the app did not start (#3716): the words of the
// Sessions list, as the window's SessionListView.
import type { RuntimeSession } from "../protocol/generated";
import { folderKey } from "./groups";

/** The worktree a conversation is in, by its folder's name, when it is not the folder itself:
 *  another tool's worktree of this folder, such as a Conductor workspace. */
export function sessionPlace(session: RuntimeSession, folder: string): string | undefined {
  const here = folderKey(session.cwd);
  if (here === folderKey(folder)) return undefined;
  return decodeURI(here.split("/").pop() ?? "") || undefined;
}

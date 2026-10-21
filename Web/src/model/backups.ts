// Settings ▸ Backups (#1810): the words the section says, as the window's and the Remote's
// BackupsSection says them (Shared/UI/BackupsSection.swift).
import type { Backup, BackupEvery, BackupRestoreResult } from "../protocol/generated";

export const backupEveries: readonly BackupEvery[] = ["off", "daily", "weekly"];

export const backupKeeps: readonly number[] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];

export function everyLabel(every: BackupEvery): string {
  switch (every) {
    case "off": return "Never";
    case "daily": return "Every day";
    case "weekly": return "Every week";
  }
}

export const backupsFooter = "A backup holds this machine's agents, their conversations, and its usage and time history. "
  + "It never holds a sign-in or a secret. Restore brings a backup's agents back archived; "
  + "one this machine has already is left as it is. An agent from another machine is shown, never run.";

export const restoreMessage = "Its agents come back archived. Nothing on this machine is changed or deleted.";

function bytesWords(bytes: number): string {
  if (bytes < 1000) return `${bytes} bytes`;
  const units = ["KB", "MB", "GB", "TB"];
  let n = bytes / 1000;
  let unit = 0;
  while (n >= 1000 && unit < units.length - 1) { n /= 1000; unit++; }
  return `${n < 10 ? n.toFixed(1) : Math.round(n)} ${units[unit]}`;
}

export function backupDetail(backup: Backup): string {
  const agents = backup.agents === 1 ? "1 agent" : `${backup.agents} agents`;
  return [backup.thisMachine ? "This machine" : backup.machine, agents, bytesWords(backup.bytes)].join(" · ");
}

export function confirmTitle(backup: Backup): string {
  return backup.thisMachine ? "Restore this backup?" : `Restore the backup of ${backup.machine}?`;
}

export function restoredWords(result: BackupRestoreResult): string {
  const back = result.restored === 1 ? "1 agent" : `${result.restored} agents`;
  const here = result.skipped === 1 ? "1 agent was here already." : `${result.skipped} agents were here already.`;
  if (result.restored === 0) return result.skipped === 0 ? "The backup holds no agents." : `Nothing to restore: ${here}`;
  return result.skipped === 0 ? `Restored ${back}, archived.` : `Restored ${back}, archived. ${here}`;
}

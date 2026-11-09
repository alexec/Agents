// Settings ▸ Machines ▸ Sleep's words (#4066), as the window's Settings ▸ Machines ▸ This Mac ▸ Sleep says them:
// how many finished sessions keep their runtime ready for a reply (#183), and how long a runtime whose background
// processes still run is kept (#4044).

/** "Keep ready for a reply": none to eight sessions, as `WakeSettings.warmRange`. */
export const warmCounts = [0, 1, 2, 3, 4, 5, 6, 7, 8] as const;

/** "Keep runtimes with background processes": one to 24 hours, as `WakeSettings.backgroundRange`. */
export const backgroundHourChoices: readonly number[] = Array.from({ length: 24 }, (_, i) => i + 1);

/** The host's default when a host before #4044 does not say. */
export const defaultBackgroundHours = 4;

export function sessionsLabel(count: number): string {
  if (count === 0) return "None";
  return count === 1 ? "1 session" : `${count} sessions`;
}

export function hoursLabel(hours: number): string {
  return hours === 1 ? "1 hour" : `${hours} hours`;
}

/** The section's footer: what the two pickers keep, and that neither keeps the Mac awake. */
export function sleepFooter(backgroundHours: number): string {
  return "The sessions you are most likely to reply to keep their agent running for 10 minutes after their turn ends, "
    + "so the reply starts at once. An agent whose background processes still run (a dev server, a build, a watcher) "
    + `is kept for ${hoursLabel(backgroundHours)}, then ended with them. Neither keeps the Mac awake.`;
}

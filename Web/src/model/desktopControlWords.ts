// The pause card's words (#3004, US3): an agent's drive_screen paused by the person's own touch,
// in the window's words, DesktopControlPauseWords (Shared/UI/Chat/DesktopControlPauseCard.swift).

export function pauseTitle(app: string): string {
  return app ? `Paused driving ${app}: you used the mouse or keyboard` : "Paused: you used the mouse or keyboard";
}
export const pauseBody = "The agent stopped so it does not fight you for the screen. Resume lets it go on from where it stopped. Take Over gives you the screen back for the rest of this turn.";
export const resumeLabel = "Resume";
export const takeOverLabel = "Take Over";
export const takeOverHelp = "Let go of the screen lease now. The agent does not drive the screen again in this turn.";

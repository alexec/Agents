// The transcript entry some other pane asked the chat to bring into view (the window's
// focusedEntry). Cleared once the chat has scrolled to it.
import { signal } from "@preact/signals";

export const focusedEntry = signal<string | null>(null);
/** Where that entry is in the transcript, when Find knows it (#1532): one in a stored turn's steps is drawn once the turn is open. */
export const focusedIndex = signal<number | null>(null);

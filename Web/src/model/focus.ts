// The transcript entry some other pane asked the chat to bring into view (the window's
// focusedEntry). Cleared once the chat has scrolled to it.
import { signal } from "@preact/signals";

export const focusedEntry = signal<string | null>(null);

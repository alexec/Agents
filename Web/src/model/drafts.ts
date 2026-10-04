// What is typed and not sent, kept per session and per new-agent form across a reload, as the
// window keeps its drafts across a relaunch (#254). In localStorage, bounded: the most recent
// drafts only, and a draft's attachments only while they are small; the words are always kept.
import type { Attachment } from "../protocol/generated";

export interface Draft { text: string; attachments: Attachment[] }

interface Storage { getItem(key: string): string | null; setItem(key: string, value: string): void }

const storageKey = "agents.drafts";
/** The most drafts kept. */
export const draftsKept = 40;
/** The most a draft's attachments may take, as JSON, to be kept with it. */
export const attachmentsKept = 256 * 1024;

export class Drafts {
  private readonly held = new Map<string, Draft>();

  constructor(private readonly storage: Storage | undefined) {
    try {
      const kept = JSON.parse(storage?.getItem(storageKey) ?? "[]") as [string, Draft][];
      for (const [key, draft] of kept) {
        if (typeof draft?.text === "string") this.held.set(key, { text: draft.text, attachments: draft.attachments ?? [] });
      }
    } catch { /* unreadable: start empty */ }
  }

  get(key: string): Draft | undefined {
    return this.held.get(key);
  }

  set(key: string, draft: Draft): void {
    this.held.delete(key);
    if (draft.text === "" && draft.attachments.length === 0) { this.save(); return; }
    this.held.set(key, draft);
    while (this.held.size > draftsKept) this.held.delete(this.held.keys().next().value!);
    this.save();
  }

  delete(key: string): void {
    if (this.held.delete(key)) this.save();
  }

  private save(): void {
    if (!this.storage) return;
    const kept = [...this.held].map(([key, draft]): [string, Draft] => {
      const small = JSON.stringify(draft.attachments).length <= attachmentsKept;
      return [key, { text: draft.text, attachments: small ? draft.attachments : [] }];
    });
    try { this.storage.setItem(storageKey, JSON.stringify(kept)); } catch { /* full: kept in memory */ }
  }
}

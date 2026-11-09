// A secret's Description field (#4167) on a sheet that adds or replaces one, and on the ask_secret card:
// one or two sentences, with the words that it is not sealed. As the window's SecretDescriptionField
// (Shared/UI/UserScope/SecretsPane.swift).
import type { Signal } from "@preact/signals";
import { descriptionHint, descriptionLabel, descriptionPrompt } from "../model/userScope";

export function SecretDescriptionField({ text, disabled }: { text: Signal<string>; disabled?: boolean }) {
  return (
    <>
      <textarea aria-label={descriptionLabel} placeholder={descriptionPrompt} rows={2} disabled={disabled} value={text.value}
        onInput={(e) => (text.value = (e.currentTarget as HTMLTextAreaElement).value)} />
      <p class="sheet-note">{descriptionHint}</p>
    </>
  );
}

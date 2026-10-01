// The prompt (071 FR-025): text and attachments, dropped, pasted or picked, sent as the Remote
// sends them (PhoneAttachment's rules), with the draft kept per session in memory. Return sends;
// Shift-Return is a new line, as in the window.
import { useSignal } from "@preact/signals";
import { useEffect, useRef } from "preact/hooks";
import type { ComponentChildren } from "preact";
import type { ACPPromptCapabilities, Attachment } from "../protocol/generated";
import type { Store } from "../model/store";
import { attach, refusal, totalRefusal } from "../model/attachments";

export function Prompt({ store, draftKey, placeholder, capabilities, disabled, send, children }: {
  store: Store;
  /** Where the draft is kept: a session, or a new-agent form. */
  draftKey: string;
  placeholder: string;
  capabilities: ACPPromptCapabilities | undefined;
  disabled: boolean;
  /** Answers whether it went, so a refused prompt keeps what was typed. */
  send: (text: string, attachments: Attachment[]) => Promise<boolean>;
  /** The menus, under the text. */
  children?: ComponentChildren;
}) {
  const kept = store.drafts.get(draftKey);
  const text = useSignal(kept?.text ?? "");
  const attachments = useSignal<Attachment[]>(kept?.attachments ?? []);
  const said = useSignal<string | null>(null);
  const sending = useSignal(false);
  const picker = useRef<HTMLInputElement>(null);

  useEffect(() => {
    const draft = store.drafts.get(draftKey);
    text.value = draft?.text ?? "";
    attachments.value = draft?.attachments ?? [];
    said.value = null;
  }, [draftKey]);

  const keep = () => store.drafts.set(draftKey, { text: text.value, attachments: attachments.value });

  const take = async (files: Iterable<File>) => {
    for (const file of files) {
      const made = await attach(file);
      if ("ok" in made) {
        attachments.value = [...attachments.value, made.ok];
        said.value = null;
      } else {
        said.value = made.refused;
      }
    }
    keep();
  };

  const tooMuch = totalRefusal(attachments.value);
  const refused = attachments.value.map((a) => refusal(a, capabilities)).find((r) => r !== null) ?? null;
  const canSend = !disabled && !sending.value && text.value.trim() !== "" && !tooMuch && !refused;

  const submit = async () => {
    if (!canSend) return;
    sending.value = true;
    const went = await send(text.value.trim(), attachments.value);
    sending.value = false;
    if (went) {
      text.value = "";
      attachments.value = [];
      store.drafts.delete(draftKey);
    }
  };

  return (
    <div class={`prompt${disabled ? " off" : ""}`}
      onDragOver={(e) => { e.preventDefault(); }}
      onDrop={(e) => {
        e.preventDefault();
        if (!disabled && e.dataTransfer?.files.length) void take(Array.from(e.dataTransfer.files));
      }}>
      {attachments.value.length > 0 && (
        <ul class="attachments" aria-label="Attached">
          {attachments.value.map((attachment) => {
            const why = refusal(attachment, capabilities);
            return (
              <li key={attachment.id}>
                <span>{attachment.block.type === "image" ? "🖼" : "📄"} {attachment.displayName}</span>
                <button class="remove" aria-label={`Remove ${attachment.displayName}`}
                  onClick={() => { attachments.value = attachments.value.filter((a) => a.id !== attachment.id); keep(); }}>×</button>
                {why && <span class="failure small">{why}</span>}
              </li>
            );
          })}
        </ul>
      )}
      <textarea aria-label="Prompt" placeholder={placeholder} disabled={disabled} rows={2} value={text.value}
        onInput={(e) => { text.value = (e.currentTarget as HTMLTextAreaElement).value; keep(); }}
        onKeyDown={(e) => {
          if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
            e.preventDefault();
            void submit();
          }
        }}
        onPaste={(e) => {
          const files = Array.from(e.clipboardData?.files ?? []);
          if (files.length && !disabled) {
            e.preventDefault();
            void take(files);
          }
        }} />
      {(said.value || tooMuch) && <p class="failure small" role="status">{said.value ?? tooMuch}</p>}
      <div class="prompt-row">
        <button class="icon attach" aria-label="Attach" title="Attach a picture or a text file" disabled={disabled}
          onClick={() => picker.current?.click()}>📎</button>
        <input ref={picker} type="file" multiple hidden onChange={(e) => {
          const input = e.currentTarget as HTMLInputElement;
          if (input.files) void take(Array.from(input.files));
          input.value = "";
        }} />
        {children}
        <button class="send" aria-label="Send" title="Send (Return)" disabled={!canSend} onClick={() => void submit()}>↑</button>
      </div>
    </div>
  );
}

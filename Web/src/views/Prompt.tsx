// The prompt (071 FR-025): text and attachments, dropped, pasted or picked, sent as the Remote
// sends them (PhoneAttachment's rules), with the draft kept per session in memory. Return sends;
// Shift-Return is a new line, as in the window.
//
// Laid out as the window's PromptBar (#108): where it works and its labels above the input on the
// left, the runtime above on the right, attach and send inside the input, and the runtime's
// menus under it.
import { useSignal } from "@preact/signals";
import { useEffect, useRef } from "preact/hooks";
import type { ComponentChildren } from "preact";
import type { ACPPromptCapabilities, Attachment } from "../protocol/generated";
import type { Store } from "../model/store";
import { attach, refusal, totalRefusal } from "../model/attachments";
import { Telling } from "./Telling";

/** A send usually lands before anyone could read a word; words only for one still going after this. */
const slowSend = 400;

export function Prompt({ store, draftKey, placeholder, capabilities, disabled, send, recipient, starting = false, where, runtime, onTyping, children }: {
  store: Store;
  /** Where the draft is kept: a session, or a new-agent form. */
  draftKey: string;
  placeholder: string;
  capabilities: ACPPromptCapabilities | undefined;
  disabled: boolean;
  /** Sending and attaching are off; typing never is. */
  /** Answers whether it went, so a refused prompt keeps what was typed. */
  send: (text: string, attachments: Attachment[]) => Promise<boolean>;
  /** Who it goes to, as the pending mark says it (#87). */
  recipient: string;
  /** A new session's bar: what is typed stays, held, until the agent exists (#87). */
  starting?: boolean;
  /** Where it works, and its labels: above the input, on the left. */
  where?: ComponentChildren;
  /** The runtime: above the input, on the right. */
  runtime?: ComponentChildren;
  /** The menus, or what is said in their place: under the input. */
  children?: ComponentChildren;
  /** Something was typed: a prompt is coming, so its runtime can start now (#183). */
  onTyping?: () => void;
}) {
  const kept = store.drafts.get(draftKey);
  const text = useSignal(kept?.text ?? "");
  const attachments = useSignal<Attachment[]>(kept?.attachments ?? []);
  const said = useSignal<string | null>(null);
  const sending = useSignal(false);
  const slow = useSignal(false);
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

  useEffect(() => {
    slow.value = false;
    if (!sending.value) return;
    const timer = setTimeout(() => (slow.value = true), slowSend);
    return () => clearTimeout(timer);
  }, [sending.value]);

  /**
   * A prompt to an agent leaves the field at once, so sending feels immediate, and is given back
   * if it did not go and nothing new was typed. A new session has no chat to show it in, so its
   * words stay in the held field under "Starting — telling your Mac" until it exists (#87).
   */
  const submit = async () => {
    if (!canSend) return;
    const outgoing = text.value.trim();
    const going = attachments.value;
    if (!starting) {
      text.value = "";
      attachments.value = [];
      store.drafts.delete(draftKey);
    }
    sending.value = true;
    const went = await send(outgoing, going);
    sending.value = false;
    if (starting && went) {
      text.value = "";
      attachments.value = [];
      store.drafts.delete(draftKey);
    } else if (!starting && !went && text.value === "" && attachments.value.length === 0) {
      text.value = outgoing;
      attachments.value = going;
      keep();
    }
  };

  return (
    <div class="bar">
      {(where || runtime) && (
        <div class="bar-head">
          <div class="bar-where">{where}</div>
          {runtime && <div class="bar-runtime">{runtime}</div>}
        </div>
      )}
      {sending.value && (starting || slow.value) && (
        <Telling recipient={recipient} doing={starting ? "Starting" : "Sending"} />
      )}
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
        <div class="prompt-field">
          {/* Never disabled: what is typed while the link is down is kept and sent once it's back (US7). */}
          <textarea aria-label="Prompt" placeholder={placeholder} rows={2} value={text.value}
            readOnly={starting && sending.value}
            onInput={(e) => {
              text.value = (e.currentTarget as HTMLTextAreaElement).value;
              keep();
              if (text.value) onTyping?.();
            }}
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
          <button class="icon attach" aria-label="Attach" title="Attach a picture or a text file" disabled={disabled}
            onClick={() => picker.current?.click()}>📎</button>
          <input ref={picker} type="file" multiple hidden onChange={(e) => {
            const input = e.currentTarget as HTMLInputElement;
            if (input.files) void take(Array.from(input.files));
            input.value = "";
          }} />
          {/* Bright while its own spinner turns, as the answer that went stays bright on the cards (#86). */}
          <button class={`send${sending.value ? " going" : ""}`} aria-label={sending.value ? tellingLabel(starting, recipient) : "Send"}
            title="Send (Return)" disabled={!canSend && !sending.value} onClick={() => void submit()}>
            {sending.value ? <span class="spinner" aria-hidden="true" /> : "↑"}
          </button>
        </div>
      </div>
      {(said.value || tooMuch) && <p class="failure small" role="status">{said.value ?? tooMuch}</p>}
      {children && <div class="bar-foot">{children}</div>}
    </div>
  );
}

function tellingLabel(starting: boolean, recipient: string): string {
  return `${starting ? "Starting" : "Sending"} — telling ${recipient}`;
}

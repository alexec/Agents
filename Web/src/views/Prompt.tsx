// The prompt (071 FR-025): text and attachments, dropped, pasted or picked, sent as the Remote
// sends them (PhoneAttachment's rules), with the draft kept per session across a reload (#254).
// Return sends; Shift-Return is a new line, as in the window. While the agent works and nothing
// is typed, Send is Stop; what is typed then is queued, and Send says so. The agent's suggestion
// is the empty field's placeholder, taken with Tab and put away with Escape, as the window's.
//
// Laid out as the window's PromptBar (#108): where it works and its labels above the input on the
// left, the runtime above on the right, attach and send inside the input, and the runtime's
// menus under it.
//
// A `/` at the start of a word lists the runtime's commands, and an `@` the files the host finds
// under the agent's folders (#255), over the field as the window's CommandList and MentionList:
// arrows move, Return or Tab takes one, Escape puts the list away for that word.
import { useSignal } from "@preact/signals";
import { useEffect, useRef } from "preact/hooks";
import type { ComponentChildren } from "preact";
import type { ACPPromptCapabilities, Attachment, FileMentionDTO, SlashCommand, SuggestedPrompt, UUID } from "../protocol/generated";
import { sendHelp, sendLabel, stopHelp } from "../model/promptWords";
import type { Store } from "../model/store";
import { attach, refusal, totalRefusal } from "../model/attachments";
import { Telling } from "./Telling";
import { commandQuery, completeCommand, completeMention, fileName, fileURL, matchingCommands, mentionQuery } from "../model/completions";

/** A send usually lands before anyone could read a word; words only for one still going after this. */
const slowSend = 400;

/** A word typed quickly is one question to the host, not six, as the Remote's. */
const mentionPause = 150;

export function Prompt({ store, draftKey, placeholder, capabilities, disabled, send, recipient, starting = false, where, runtime, onTyping, children,
  stop, queues = false, suggestion, commands = [], findFiles, banner }: {
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
  /** While the agent works: Send is this, with nothing typed (#254). */
  stop?: (() => void) | undefined;
  /** What is typed now will wait for the turn to end. */
  queues?: boolean;
  /** What the agent offers to be asked next (031). */
  suggestion?: SuggestedPrompt | undefined;
  /** What the runtime takes after a slash: the agent's, or the new session's draft's. */
  commands?: readonly SlashCommand[] | undefined;
  /** Files under the agent's folders matching what follows an `@`, found by its host. */
  findFiles?: ((term: string) => Promise<FileMentionDTO[]>) | undefined;
  /** A limit notice, above the field as in both Swift clients. */
  banner?: ComponentChildren;
}) {
  const kept = store.drafts.get(draftKey);
  const text = useSignal(kept?.text ?? "");
  const attachments = useSignal<Attachment[]>(kept?.attachments ?? []);
  const said = useSignal<string | null>(null);
  const sending = useSignal(false);
  const slow = useSignal(false);
  const picker = useRef<HTMLInputElement>(null);
  // Escape puts the suggestion away until the agent offers another.
  const dismissed = useSignal<string | null>(null);
  const mentions = useSignal<FileMentionDTO[]>([]);
  const selected = useSignal(0);
  // The word whose list Escape put away; typing on brings it back.
  const putAway = useSignal<string | null>(null);
  const search = useRef(0);

  const command = commandQuery(text.value);
  const matching = command ? matchingCommands(command.term, commands) : [];
  const mention = mentionQuery(text.value);
  const listing: "commands" | "mentions" | null =
    command && matching.length && putAway.value !== `/${command.term}` ? "commands"
    : mention && mentions.value.length && putAway.value !== `@${mention.term}` ? "mentions"
    : null;
  const offered = !listing && suggestion && dismissed.value !== suggestion.id && text.value === "" ? suggestion : undefined;
  // A different word, or none, ends what Escape put away, so the same word typed again lists again.
  const word = command ? `/${command.term}` : mention ? `@${mention.term}` : null;
  if (putAway.value !== null && putAway.value !== word) putAway.value = null;

  useEffect(() => {
    const turn = ++search.current;
    const term = mention?.term ?? "";
    if (!findFiles || !term) {
      mentions.value = [];
      return;
    }
    const timer = setTimeout(() => {
      void findFiles(term).then((found) => {
        if (search.current === turn) mentions.value = found;
      }, () => {
        if (search.current === turn) mentions.value = [];
      });
    }, mentionPause);
    return () => clearTimeout(timer);
  }, [mention?.term, findFiles]);

  useEffect(() => {
    const draft = store.drafts.get(draftKey);
    text.value = draft?.text ?? "";
    attachments.value = draft?.attachments ?? [];
    said.value = null;
    putAway.value = null;
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

  /** Takes the chosen command or file into the field; a file goes with the words as the host's own path. */
  const accept = (index: number) => {
    if (listing === "commands" && command) {
      const chosen = matching[index];
      if (chosen) text.value = completeCommand(text.value, command, chosen);
    } else if (listing === "mentions" && mention) {
      const chosen = mentions.value[index];
      if (!chosen) return;
      const name = fileName(chosen.path);
      text.value = completeMention(text.value, mention, name);
      attachments.value = [...attachments.value, {
        id: crypto.randomUUID().toUpperCase() as UUID,
        block: { type: "resource_link", uri: fileURL(chosen.path), name },
        displayName: name,
      }];
      mentions.value = [];
    }
    selected.value = 0;
    keep();
  };
  const listLength = listing === "commands" ? matching.length : listing === "mentions" ? mentions.value.length : 0;
  const chosenIndex = Math.min(selected.value, Math.max(0, listLength - 1));

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
      {banner}
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
        {listing === "commands" && (
          <ul class="completions" role="listbox" aria-label="Commands">
            {matching.map((c, i) => (
              <li key={c.name} role="option" aria-selected={i === chosenIndex} class={i === chosenIndex ? "chosen" : ""}
                ref={(el) => { if (el && i === chosenIndex) el.scrollIntoView({ block: "nearest" }); }}
                onMouseDown={(e) => { e.preventDefault(); accept(i); }}>
                <code>/{c.name}</code>
                {c.inputHint && <code class="quiet">{c.inputHint}</code>}
                {c.description && <span class="quiet small">{c.description}</span>}
              </li>
            ))}
          </ul>
        )}
        {listing === "mentions" && (
          <ul class="completions" role="listbox" aria-label="Files">
            {mentions.value.map((m, i) => (
              <li key={m.path} role="option" aria-selected={i === chosenIndex} class={i === chosenIndex ? "chosen" : ""}
                ref={(el) => { if (el && i === chosenIndex) el.scrollIntoView({ block: "nearest" }); }}
                onMouseDown={(e) => { e.preventDefault(); accept(i); }}>
                <span>{fileName(m.path)}</span>
                <span class="quiet small">{m.relativePath}</span>
              </li>
            ))}
          </ul>
        )}
        <div class="prompt-field">
          {/* Never disabled: what is typed while the link is down is kept and sent once it's back (US7). */}
          <textarea aria-label="Prompt" placeholder={offered ? `${offered.prompt}  (Tab)` : placeholder} rows={2} value={text.value}
            readOnly={starting && sending.value}
            onInput={(e) => {
              text.value = (e.currentTarget as HTMLTextAreaElement).value;
              selected.value = 0;
              keep();
              if (text.value) onTyping?.();
            }}
            onKeyDown={(e) => {
              if (listing && !e.isComposing) {
                // While the list is up, Return takes the command rather than sending a half-typed one.
                if ((e.key === "Enter" && !e.shiftKey) || (e.key === "Tab" && !e.shiftKey)) {
                  e.preventDefault();
                  accept(chosenIndex);
                  return;
                }
                if (e.key === "ArrowDown" || e.key === "ArrowUp") {
                  e.preventDefault();
                  selected.value = Math.max(0, Math.min(listLength - 1, chosenIndex + (e.key === "ArrowDown" ? 1 : -1)));
                  return;
                }
                if (e.key === "Escape") {
                  e.preventDefault();
                  putAway.value = listing === "commands" ? `/${command?.term}` : `@${mention?.term}`;
                  return;
                }
              }
              if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
                e.preventDefault();
                void submit();
              } else if (e.key === "Tab" && !e.shiftKey && offered) {
                // Taken into the field, not sent: sending it is still the person's move.
                e.preventDefault();
                text.value = offered.prompt;
                keep();
              } else if (e.key === "Escape" && offered) {
                dismissed.value = offered.id;
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
          {stop && !sending.value && text.value.trim() === "" && attachments.value.length === 0 ? (
            // The one way to stop it, where Send is, as PromptWords.stopSymbol (#254).
            <button class="send stop" aria-label="Stop" title={stopHelp} disabled={disabled} onClick={stop}>■</button>
          ) : (
            <button class={`send${sending.value ? " going" : ""}`} aria-label={sending.value ? tellingLabel(starting, recipient) : sendLabel(queues)}
              title={`${sendHelp(queues)} (Return)`} disabled={!canSend && !sending.value} onClick={() => void submit()}>
              {sending.value ? <span class="spinner" aria-hidden="true" /> : queues ? "⤒" : "↑"}
            </button>
          )}
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

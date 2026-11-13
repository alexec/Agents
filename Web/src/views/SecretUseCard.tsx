// A use of a secret with Ask before use (#4017, #4918), as an Ask (#5031) at the end of the chat of the
// session that asked, as a permission question is: which secret, and where its value goes, never
// the value. Its buttons are the request's answers, the same as its Needs You row's menu, and they go
// the same way (store.answerSecretUse); requests/changed takes the card and the row away together.
// A terminal's (#4179) has no session, so it has no card. The window and the Remote draw SecretUseCard.swift.
import { useSignal } from "@preact/signals";
import type { Request as PersonRequest } from "../protocol/generated";
import type { Store } from "../model/store";
import { Ask, AskMore } from "./Ask";
import { answerElsewhere, type SecretUseAction, secretUseActions, secretUseOf, secretUseSigns, secretUseTitle, secretUseWhere, secretUseWords } from "../model/secretUse";

export function SecretUseCard({ store, host, request, disabled }: { store: Store; host: string; request: PersonRequest; disabled: boolean }) {
  const busy = useSignal(false);
  const use = secretUseOf(request);
  if (!use) return null;
  // A page with no lock key cannot allow a Linux machine's use (#4149): Deny only, and where to allow it.
  const unsigned = secretUseSigns(use, "once") && !store.machineLock.canSign();
  const actions = secretUseActions(use).filter((action) => !unsigned || !secretUseSigns(use, action)).reverse();
  const title = secretUseTitle(use);
  const answer = (action: SecretUseAction) => {
    busy.value = true;
    void store.answerSecretUse(host, request.id, action, use).finally(() => (busy.value = false));
  };
  // Approve is the primary button, the next one beside it, the rest in ⋯, and Deny on the left (spec rule 2).
  const approving = actions.filter((action) => action !== "deny").reverse();
  const [primary, second, ...more] = approving;
  const held = disabled || busy.value;
  const button = (action: SecretUseAction, prominent = false) => (
    <button key={action} class={prominent ? "prominent" : undefined} disabled={held} {...(prominent ? { "data-default": "" } : {})}
      onClick={() => answer(action)}>{secretUseWords[action]}</button>
  );
  return (
    <Ask glyph="lock" title={title} label={title} alert extra="secret-use-card"
      decline={actions.includes("deny") && <button class="link" disabled={held} onClick={() => answer("deny")}>{secretUseWords.deny}</button>}
      buttons={<>
        {more.length > 0 && <AskMore>{more.map((action) => button(action))}</AskMore>}
        {second && button(second)}
        {primary && button(primary, true)}
      </>}>
      <p class="quiet">{unsigned ? `${secretUseWhere(use)} · ${answerElsewhere}` : secretUseWhere(use)}</p>
    </Ask>
  );
}

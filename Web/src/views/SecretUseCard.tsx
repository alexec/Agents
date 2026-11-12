// A use of a secret with Ask before use (#4017, #4918), as a card at the end of the chat of the
// session that asked, as a permission question is: which secret, and where its value goes, never
// the value. Its buttons are the request's answers, the same as its Needs You row's menu, and they go
// the same way (store.answerSecretUse); requests/changed takes the card and the row away together.
// A terminal's (#4179) has no session, so it has no card. The window and the Remote draw SecretUseCard.swift.
import { useSignal } from "@preact/signals";
import type { Request as PersonRequest } from "../protocol/generated";
import type { Store } from "../model/store";
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
  return (
    <div class="cards">
      <div class="card secret-use-card" role="alert" aria-label={title}>
        <p class="strong">{title}</p>
        <p class="quiet">{unsigned ? `${secretUseWhere(use)} · ${answerElsewhere}` : secretUseWhere(use)}</p>
        <p class="secret-use-answers">
          {actions.map((action) => (
            <button key={action} class={action === "once" ? "prominent" : undefined} disabled={disabled || busy.value}
              onClick={() => answer(action)}>{secretUseWords[action]}</button>
          ))}
        </p>
      </div>
    </div>
  );
}

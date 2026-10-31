// A GitHub sign-in on a new client, waiting for this person's Approve (#995, spec 736 FR-010), as the
// window's and the Remote's card (Shared/UI/SignIn/SignInRequestCard.swift): the client's name, the
// GitHub account, the code it shows, and Approve or Deny. At the top of the sidebar beside the join
// cards. A GitHub token carries no nonce, so only the person's own client says the new one is theirs.
// A browser that asked by an account (#2097) has no code on the card: the person types the one it shows.
import { useSignal } from "@preact/signals";
import type { Store } from "../model/store";
import type { SignInRequest } from "../protocol/generated";
import { account, liveSignIns, needsCode, typeCode, wants } from "../model/signIn";
import { ApprovalMark } from "./Approval";

function SignInCard({ store, request, down }: { store: Store; request: SignInRequest; down: boolean }) {
  const title = `${request.name} ${wants} ${account(request)}`;
  const typed = useSignal("");
  const asksCode = needsCode(request);
  const code = typed.value.trim();
  const approve = () => void store.decideSignIn(request.request, true, asksCode ? code : undefined);
  return (
    <li class="join-request" aria-label={title}>
      <ApprovalMark />
      <div class="body">
        <span class="title"><strong>{request.name}</strong> {wants}</span>
        <span class="subtitle">{account(request)}</span>
        {asksCode ? (
          <label class="subtitle sign-in-code">
            {typeCode}
            <input type="text" aria-label="Code" autocomplete="off" spellcheck={false} value={typed.value}
              onInput={(e) => (typed.value = (e.currentTarget as HTMLInputElement).value)}
              onKeyDown={(e) => {
                if (e.key === "Enter" && code) {
                  e.preventDefault();
                  approve();
                }
              }} />
          </label>
        ) : (
          <span class="subtitle">Check that it shows <code>{request.code}</code>.</span>
        )}
        <div class="join-actions">
          <button type="button" disabled={down} onClick={() => void store.decideSignIn(request.request, false)}>Deny</button>
          <button type="button" class="prominent" disabled={down || (asksCode && !code)} onClick={approve}>Approve</button>
        </div>
      </div>
    </li>
  );
}

/** Every GitHub sign-in waiting for this person, or nothing. */
export function SignInRequests({ store, down }: { store: Store; down: boolean }) {
  const waiting = liveSignIns(store.signInRequests.value);
  if (waiting.length === 0) return null;
  return (
    <section class="join-requests" aria-label="Sign-ins waiting for approval">
      <ul>{waiting.map((request) => <SignInCard key={request.request} store={store} request={request} down={down} />)}</ul>
    </section>
  );
}

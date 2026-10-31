// Sign-in on the web page (#995, spec 736 T2), as the window's and the Remote's: Control plane ▸ Sign-ins lists
// how this person signs in, with Remove (Shared/UI/SignIn/SignInsSection.swift), and Control plane ▸
// Sign-in Providers lets an admin turn providers on and allow domains and organisations
// (Shared/UI/SignIn/SignInPane.swift). A browser adds no sign-in: it pairs with a code (FR-014).
import { useEffect } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { Store } from "../model/store";
import type { SignIn, SignInConfigure, SignInProviders } from "../protocol/generated";
import { describe } from "../model/errors";
import {
  domainsFoot, domainsTitle, isOutside, list, organisationsFoot, organisationsTitle, paneFoot, paneTitle, providerTitle,
  removeMessage, removeTitle, row, signInsFoot, signInsNone, signInsTitle,
} from "../model/signIn";

/** Control plane ▸ Sign-ins: this person's sign-ins, each outside one with Remove. */
export function SignInsSection({ store, down }: { store: Store; down: boolean }) {
  // From the store's one people list (#2055), loaded on each connection and each control/peopleChanged.
  const list = store.people.value;
  const failure = store.peopleFailure.value;
  const problem = failure ? describe(failure) : null;
  const remove = async (signIn: SignIn) => {
    if (!signIn.account || !window.confirm(`${removeTitle(signIn)} ${removeMessage}`)) return;
    try {
      // The change comes back as control/peopleChanged.
      await store.link.call("signIn/removeFromMe", { provider: signIn.provider, account: signIn.account });
    } catch (error) {
      store.say(describe(error));
    }
  };
  const shown: SignIn[] | null = list ? list.people.find((p) => p.you)?.signIns ?? [] : null;
  return (
    <section aria-labelledby="settings-signins">
      <h3 class="section-head" id="settings-signins">{signInsTitle}</h3>
      {problem && <p class="hint">{problem}</p>}
      {!shown && !problem && <p class="hint">Loading…</p>}
      {shown && shown.length === 0 && <p class="hint">{signInsNone}</p>}
      {shown && shown.length > 0 && (
        <ul class="people-list">
          {shown.map((signIn) => (
            <li key={`${signIn.provider}\n${signIn.account ?? ""}`} class="person">
              <div class="person-things">
                <span>{row(signIn)}</span>
                {isOutside(signIn.provider) && signIn.account && (
                  <span>
                    <button type="button" class="link destructive" disabled={down} onClick={() => void remove(signIn)}>Remove…</button>
                  </span>
                )}
              </div>
            </li>
          ))}
        </ul>
      )}
      <p class="hint">{signInsFoot}</p>
    </section>
  );
}

/** Control plane ▸ Sign-in Providers, for admins: the providers, and the allowed domains and organisations. */
export function SignInSection({ store, down }: { store: Store; down: boolean }) {
  const providers = useSignal<SignInProviders | null>(null);
  const problem = useSignal<string | null>(null);
  const domains = useSignal("");
  const organisations = useSignal("");
  const saving = useSignal(false);
  const shown = (answer: SignInProviders) => {
    providers.value = answer;
    domains.value = (answer.domains ?? []).join(", ");
    organisations.value = (answer.organisations ?? []).join(", ");
  };
  const load = async () => {
    try {
      shown(await store.link.call("signIn/providers", {}));
      problem.value = null;
    } catch (error) {
      problem.value = describe(error);
    }
  };
  const changes = store.peopleChanges.value;
  useEffect(() => { if (!down) void load(); }, [changes, down]);
  const configure = async (change: SignInConfigure) => {
    saving.value = true;
    try {
      shown(await store.link.call("signIn/configure", change));
      problem.value = null;
    } catch (error) {
      problem.value = describe(error);
    }
    saving.value = false;
  };
  const answer = providers.value;
  const same = (text: string, kept: string[] | undefined) => list(text).join(",") === (kept ?? []).join(",");
  return (
    <section aria-labelledby="settings-signin">
      <h3 class="section-head" id="settings-signin">{paneTitle}</h3>
      {problem.value && <p class="hint">{problem.value}</p>}
      {!answer && !problem.value && <p class="hint">Loading…</p>}
      {answer && (
        <>
          {answer.providers.map((p) => (
            <div key={p.provider}>
              <label class="setting">
                <span>{providerTitle(p.provider)}</span>
                <input type="checkbox" role="switch" checked={p.on} disabled={down || saving.value || !p.available}
                  onChange={(e) => void configure({ provider: p.provider, on: e.currentTarget.checked })} />
              </label>
              {p.why && <p class="hint">{p.why}</p>}
            </div>
          ))}
          <p class="hint">{paneFoot}</p>
          <label class="setting">
            <span>{domainsTitle}</span>
            <input type="text" placeholder="example.com, example.org" value={domains.value} disabled={down}
              onInput={(e) => (domains.value = e.currentTarget.value)} />
          </label>
          <button type="button" disabled={down || saving.value || same(domains.value, answer.domains)}
            onClick={() => void configure({ provider: "google", domains: list(domains.value) })}>Save Domains</button>
          <p class="hint">{domainsFoot}</p>
          <label class="setting">
            <span>{organisationsTitle}</span>
            <input type="text" placeholder="acme" value={organisations.value} disabled={down}
              onInput={(e) => (organisations.value = e.currentTarget.value)} />
          </label>
          <button type="button" disabled={down || saving.value || same(organisations.value, answer.organisations)}
            onClick={() => void configure({ provider: "github", organisations: list(organisations.value) })}>Save Organisations</button>
          <p class="hint">{organisationsFoot}</p>
        </>
      )}
    </section>
  );
}

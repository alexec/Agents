// Console ▸ Sign-In (#1002, spec 1002 FR-030): the built-in providers (as Settings has them), and the
// organisation's own: Add Provider with presets, the redirect URI to copy, Check, Edit, Replace Secret (written
// only), Who may join, the order on the sign-in screen and Remove. Under each, its claimed domains (the TXT
// record, Check, Send people here, Require this provider with the preview of FR-012) and its SCIM (Turn On SCIM,
// the base URL, the match attribute, tokens shown once, their last use, Revoke).
import { useEffect } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { Store } from "../model/store";
import type { DomainClaim, OrgProviderKept, SCIMMatch, SCIMToken, SCIMTokenMade } from "../protocol/generated";
import { failedWords } from "../model/console";
import { checkWords, domainWords, domainsFoot, inOrder, issuerHints, joinNames, joins, matchNames, moved, newProviderForm, noOrgProviders, orgFoot,
  presetNames, presets, previewWords, providerFormOf, providerOf, scimBaseURL, scimFoot, secretWords, tokenWords, withPreset } from "../model/orgSignIn";
import type { ProviderForm } from "../model/orgSignIn";
import { SignInSection } from "./SignInSection";

type Open = { kind: "list" } | { kind: "edit"; kept: OrgProviderKept | null; form: ProviderForm } | { kind: "secret"; kept: OrgProviderKept; secret: string };

export function SignInPage({ store, down }: { store: Store; down: boolean }) {
  const providers = useSignal<OrgProviderKept[] | null>(null);
  const domains = useSignal<DomainClaim[]>([]);
  const problem = useSignal<string | null>(null);
  const said = useSignal<string | null>(null);
  const busy = useSignal(false);
  const open = useSignal<Open>({ kind: "list" });
  const load = async () => {
    try {
      const [p, d] = await Promise.all([store.link.call("signIn/orgProviders/list", {}), store.link.call("signIn/domains/list", {})]);
      providers.value = inOrder(p.providers);
      domains.value = d.domains;
      problem.value = null;
    } catch (error) {
      problem.value = failedWords(error);
    }
  };
  const changes = store.peopleChanges.value;
  useEffect(() => { if (!down) void load(); }, [down, changes]);
  const run = async (work: () => Promise<string | null>) => {
    busy.value = true;
    try {
      said.value = await work();
      problem.value = null;
    } catch (error) {
      problem.value = failedWords(error);
    } finally {
      busy.value = false;
    }
  };
  const save = (form: ProviderForm, kept: OrgProviderKept | null) => run(async () => {
    const made = providerOf(form, kept?.provider);
    if ("problem" in made) { problem.value = made.problem; return null; }
    const order = kept ? {} : { order: providers.value?.length ?? 0 };
    const result = await store.link.call("signIn/orgProviders/set", { provider: { ...made.provider, ...order },
      ...(made.secret !== undefined && { secret: made.secret }), ...(kept && { rev: kept.rev }) });
    open.value = { kind: "list" };
    await load();
    return `Saved ${result.provider.name}. Register ${result.provider.redirectURI ?? "the redirect URI"} at the provider if you have not.`;
  });
  const replaceSecret = (kept: OrgProviderKept, secret: string) => run(async () => {
    if (secret.trim() === "") { problem.value = "Type the new client secret."; return null; }
    await store.link.call("signIn/orgProviders/set", { provider: kept.provider, secret: secret.trim(), rev: kept.rev });
    open.value = { kind: "list" };
    await load();
    return `Replaced the secret of ${kept.provider.name}.`;
  });
  const check = (kept: OrgProviderKept) => run(async () =>
    checkWords(kept.provider.name, await store.link.call("signIn/orgProviders/check", { id: kept.provider.id })));
  const turn = (kept: OrgProviderKept, on: boolean) => run(async () => {
    await store.link.call("signIn/orgProviders/set", { provider: { ...kept.provider, on }, rev: kept.rev });
    await load();
    return on ? `${kept.provider.name} signs people in again.` : `${kept.provider.name} is off: it signs nobody in until it is on.`;
  });
  const move = (kept: OrgProviderKept, by: -1 | 1) => run(async () => {
    const list = providers.value ?? [];
    const ids = moved(list.map((k) => k.provider.id), kept.provider.id, by);
    for (const [order, id] of ids.entries()) {
      const k = list.find((x) => x.provider.id === id)!;
      if ((k.provider.order ?? 0) !== order) await store.link.call("signIn/orgProviders/set", { provider: { ...k.provider, order }, rev: k.rev });
    }
    await load();
    return null;
  });
  const remove = (kept: OrgProviderKept) => {
    if (!window.confirm(`Remove ${kept.provider.name}?\n\nNobody can sign in with it again, and its domains and SCIM go with it. People with no other sign-in keep their clients until their keys end.`)) return;
    void run(async () => {
      await store.link.call("signIn/orgProviders/remove", { id: kept.provider.id, rev: kept.rev });
      await load();
      return `Removed ${kept.provider.name}.`;
    });
  };
  const shown = providers.value;
  const now = open.value;
  return (
    <div class="model-access">
      <SignInSection store={store} down={down} />
      <h3 class="section-head">Your Organisation’s Providers</h3>
      {problem.value && <p class="hint" role="alert">{problem.value}</p>}
      {said.value && <p class="quiet small" role="status">{said.value}</p>}
      {!shown && !problem.value && <p class="hint">Loading…</p>}
      {now.kind === "edit" && (
        <ProviderEditor form={now.form} kept={now.kept} busy={busy.value || down} change={(form) => { open.value = { ...now, form }; }}
          save={() => void save(now.form, now.kept)} cancel={() => { open.value = { kind: "list" }; problem.value = null; }} />
      )}
      {now.kind === "secret" && (
        <form class="org-policy" onSubmit={(e) => { e.preventDefault(); void replaceSecret(now.kept, now.secret); }}>
          <h3 class="section-head">Replace the Secret of {now.kept.provider.name}</h3>
          <label class="setting">
            <span>Client secret</span>
            <input type="password" autocomplete="new-password" placeholder="Not shown again" aria-label="Client secret" value={now.secret}
              onInput={(e) => { open.value = { ...now, secret: (e.currentTarget as HTMLInputElement).value }; }} />
          </label>
          <p class="hint">The old secret is not shown, and stops working at once.</p>
          <div class="sheet-actions">
            <button type="button" disabled={busy.value} onClick={() => { open.value = { kind: "list" }; }}>Cancel</button>
            <button type="submit" class="prominent" disabled={busy.value || down}>Replace Secret</button>
          </div>
        </form>
      )}
      {shown && now.kind === "list" && (
        <>
          {shown.length === 0 && <p class="hint">{noOrgProviders}</p>}
          {shown.map((kept, at) => {
            const p = kept.provider;
            return (
              <section key={p.id} class="bot-card" aria-labelledby={`org-${p.id}`}>
                <h3 id={`org-${p.id}`}>
                  {p.name}<span class="quiet small"> · {presetNames[p.preset]}{p.on === false ? " · Off" : ""}</span>
                </h3>
                <div class="person-things">
                  <span class="faint small">Issuer</span><span class="small">{p.issuer}</span>
                  <span class="faint small">Client ID</span><span class="small">{p.clientID}</span>
                  <span class="faint small">Who may join</span><span class="small">{joinNames[p.join ?? "invite"]}</span>
                  <span class="faint small">Secret</span><span class="small">{secretWords(p)}</span>
                  {p.redirectURI && (
                    <>
                      <span class="faint small">Redirect URI</span>
                      <span class="small"><code>{p.redirectURI}</code> <CopyButton text={p.redirectURI} /></span>
                    </>
                  )}
                </div>
                <div class="org-actions">
                  <button type="button" class="link" disabled={busy.value || down} onClick={() => void check(kept)}>Check</button>
                  <button type="button" class="link" disabled={busy.value || down}
                    onClick={() => { said.value = null; open.value = { kind: "edit", kept, form: providerFormOf(p) }; }}>Edit…</button>
                  <button type="button" class="link" disabled={busy.value || down}
                    onClick={() => { said.value = null; open.value = { kind: "secret", kept, secret: "" }; }}>Replace Secret…</button>
                  <button type="button" class="link" disabled={busy.value || down || at === 0} onClick={() => void move(kept, -1)}>Move Up</button>
                  <button type="button" class="link" disabled={busy.value || down || at === shown.length - 1} onClick={() => void move(kept, 1)}>Move Down</button>
                  <button type="button" class="link" disabled={busy.value || down} onClick={() => void turn(kept, p.on === false)}>{p.on === false ? "Turn On" : "Turn Off"}</button>
                  <button type="button" class="link destructive" disabled={busy.value || down} onClick={() => remove(kept)}>Remove…</button>
                </div>
                <Domains store={store} down={down} kept={kept} domains={domains.value.filter((d) => d.provider === p.id)} reload={load} />
                <Scim store={store} down={down} kept={kept} reload={load} />
              </section>
            );
          })}
          <div class="sheet-actions">
            <button type="button" class="prominent" disabled={down || !shown}
              onClick={() => { said.value = null; open.value = { kind: "edit", kept: null, form: newProviderForm("okta") }; }}>Add Provider…</button>
          </div>
          <p class="hint">{orgFoot}</p>
        </>
      )}
    </div>
  );
}

function CopyButton({ text }: { text: string }) {
  const copied = useSignal(false);
  return (
    <button type="button" class="link" onClick={() => {
      void navigator.clipboard.writeText(text).then(() => { copied.value = true; setTimeout(() => { copied.value = false; }, 2000); }, () => {});
    }}>{copied.value ? "Copied" : "Copy"}</button>
  );
}

function ProviderEditor({ form, kept, busy, change, save, cancel }: { form: ProviderForm; kept: OrgProviderKept | null; busy: boolean;
  change: (form: ProviderForm) => void; save: () => void; cancel: () => void }) {
  const set = (next: Partial<ProviderForm>) => change({ ...form, ...next });
  const text = (label: string, key: "name" | "issuer" | "clientID" | "accountClaim" | "tenant", placeholder: string) => (
    <label class="setting">
      <span>{label}</span>
      <input type="text" spellcheck={false} placeholder={placeholder} aria-label={label} value={form[key]}
        onInput={(e) => set({ [key]: (e.currentTarget as HTMLInputElement).value })} />
    </label>
  );
  return (
    <form class="org-policy" onSubmit={(e) => { e.preventDefault(); save(); }}>
      <h3 class="section-head">{kept ? `Edit ${kept.provider.name}` : "Add Provider"}</h3>
      <label class="setting">
        <span>Kind</span>
        <select aria-label="Kind" value={form.preset} onChange={(e) => change(withPreset(form, (e.currentTarget as HTMLSelectElement).value as ProviderForm["preset"]))}>
          {presets.map((p) => <option key={p} value={p}>{presetNames[p]}</option>)}
        </select>
      </label>
      {text("Name on the button", "name", "Acme Okta")}
      {text("Issuer", "issuer", issuerHints[form.preset])}
      {form.preset === "entra" && text("Tenant ID", "tenant", "From the issuer when empty")}
      {text("Client ID", "clientID", "From the provider’s app")}
      <label class="setting">
        <span>{kept?.provider.secret ? "Client secret (set; empty keeps it)" : "Client secret"}</span>
        <input type="password" autocomplete="new-password" placeholder="Not shown again" aria-label="Client secret" value={form.secret}
          onInput={(e) => set({ secret: (e.currentTarget as HTMLInputElement).value })} />
      </label>
      {text("Claim that names a person", "accountClaim", "sub")}
      <p class="hint">The claim the provider keeps for life for each person: sub, or oid for Microsoft Entra ID. It is never the email.</p>
      <label class="setting">
        <span>Who may join</span>
        <select aria-label="Who may join" value={form.join} onChange={(e) => set({ join: (e.currentTarget as HTMLSelectElement).value as ProviderForm["join"] })}>
          {joins.map((j) => <option key={j} value={j}>{joinNames[j]}</option>)}
        </select>
      </label>
      <p class="hint">An invite works with each choice. Anyone the provider signs in lets the provider’s own app assignment decide.</p>
      <div class="sheet-actions">
        <button type="button" disabled={busy} onClick={cancel}>Cancel</button>
        <button type="submit" class="prominent" disabled={busy}>{kept ? "Save" : "Add Provider"}</button>
      </div>
    </form>
  );
}

/** A provider's claimed domains (FR-010 to FR-012). */
function Domains({ store, down, kept, domains, reload }: { store: Store; down: boolean; kept: OrgProviderKept; domains: DomainClaim[];
  reload: () => Promise<void> }) {
  const typed = useSignal("");
  const problem = useSignal<string | null>(null);
  const busy = useSignal(false);
  const name = kept.provider.name;
  const run = async (work: () => Promise<void>) => {
    busy.value = true;
    try {
      await work();
      problem.value = null;
      await reload();
    } catch (error) {
      problem.value = failedWords(error);
    } finally {
      busy.value = false;
    }
  };
  const claim = () => {
    const domain = typed.value.trim().toLowerCase();
    if (!/^[a-z0-9.-]+\.[a-z]{2,}$/.test(domain)) { problem.value = "Type a domain, such as acme.com."; return; }
    void run(async () => {
      await store.link.call("signIn/domains/claim", { domain, provider: kept.provider.id });
      typed.value = "";
    });
  };
  const require = (d: DomainClaim, on: boolean) => run(async () => {
    if (on) {
      const preview = await store.link.call("signIn/domains/preview", { domain: d.domain });
      if (!window.confirm(previewWords(d.domain, name, preview.people))) return;
    }
    await store.link.call("signIn/domains/set", { domain: d.domain, require: on });
  });
  return (
    <div class="org-domains">
      <h4 class="small strong">Domains</h4>
      {problem.value && <p class="hint" role="alert">{problem.value}</p>}
      {domains.length === 0 && <p class="hint">No domains claimed for {name}.</p>}
      {domains.map((d) => (
        <div key={d.domain} class="request">
          <div>
            <span class="strong">{d.domain}</span>
            <p class="quiet small">{domainWords(d)}</p>
            <p class="small">TXT record: <code>{d.txtName}</code> <CopyButton text={d.txtName} /> with the value <code>{d.txtValue}</code> <CopyButton text={d.txtValue} /></p>
            <label class="setting">
              <span>Send people here</span>
              <input type="checkbox" role="switch" checked={d.sendHere} disabled={down || busy.value || d.state !== "proved"}
                onChange={(e) => void run(() => store.link.call("signIn/domains/set", { domain: d.domain, sendHere: e.currentTarget.checked }).then(() => {}))} />
            </label>
            <label class="setting">
              <span>Require this provider</span>
              <input type="checkbox" role="switch" checked={d.require} disabled={down || busy.value || d.state !== "proved"}
                onChange={(e) => void require(d, e.currentTarget.checked)} />
            </label>
          </div>
          <span class="request-actions">
            <button type="button" class="link" disabled={down || busy.value} onClick={() => void run(() => store.link.call("signIn/domains/check", { domain: d.domain }).then(() => {}))}>Check</button>
            <button type="button" class="link destructive" disabled={down || busy.value} onClick={() => {
              if (window.confirm(`Remove the claim on ${d.domain}? Its switches go with it.`)) void run(() => store.link.call("signIn/domains/remove", { domain: d.domain }).then(() => {}));
            }}>Remove…</button>
          </span>
        </div>
      ))}
      <form class="setting" onSubmit={(e) => { e.preventDefault(); claim(); }}>
        <input type="text" spellcheck={false} placeholder="acme.com" aria-label={`Domain for ${name}`} value={typed.value}
          onInput={(e) => { typed.value = (e.currentTarget as HTMLInputElement).value; }} />
        <button type="submit" disabled={down || busy.value || typed.value.trim() === ""}>Claim Domain</button>
      </form>
      <p class="hint">{domainsFoot}</p>
    </div>
  );
}

/** A provider's SCIM (FR-013, FR-014, FR-016). */
function Scim({ store, down, kept, reload }: { store: Store; down: boolean; kept: OrgProviderKept; reload: () => Promise<void> }) {
  const tokens = useSignal<SCIMToken[] | null>(null);
  const made = useSignal<SCIMTokenMade | null>(null);
  const naming = useSignal("");
  const problem = useSignal<string | null>(null);
  const busy = useSignal(false);
  const p = kept.provider;
  const on = p.scim?.on === true;
  const loadTokens = async () => {
    try {
      tokens.value = (await store.link.call("scim/tokens/list", { provider: p.id })).tokens;
    } catch (error) {
      problem.value = failedWords(error);
    }
  };
  useEffect(() => { if (!down && on) void loadTokens(); }, [down, on, p.id]);
  const run = async (work: () => Promise<void>) => {
    busy.value = true;
    try {
      await work();
      problem.value = null;
    } catch (error) {
      problem.value = failedWords(error);
    } finally {
      busy.value = false;
    }
  };
  const set = (next: { on: boolean; match: SCIMMatch }) => run(async () => {
    await store.link.call("scim/set", { provider: p.id, on: next.on, match: next.match });
    await reload();
  });
  const make = () => {
    const name = naming.value.trim();
    if (name === "") { problem.value = "Name the token after where it goes, such as Okta provisioning."; return; }
    void run(async () => {
      made.value = await store.link.call("scim/tokens/make", { provider: p.id, name });
      naming.value = "";
      await loadTokens();
    });
  };
  const revoke = (t: SCIMToken) => {
    if (!window.confirm(`Revoke ${t.name}? ${p.name} cannot change people with it again.`)) return;
    void run(async () => {
      await store.link.call("scim/tokens/revoke", { id: t.id });
      await loadTokens();
    });
  };
  const match = p.scim?.match ?? "externalId";
  const base = scimBaseURL(p.redirectURI);
  const live = (tokens.value ?? []).filter((t) => !t.revoked);
  return (
    <div class="org-scim">
      <h4 class="small strong">SCIM</h4>
      {problem.value && <p class="hint" role="alert">{problem.value}</p>}
      <label class="setting">
        <span>Turn On SCIM</span>
        <input type="checkbox" role="switch" checked={on} disabled={down || busy.value} onChange={(e) => void set({ on: e.currentTarget.checked, match })} />
      </label>
      {on && (
        <>
          {base && <p class="small">Base URL: <code>{base}</code> <CopyButton text={base} /></p>}
          <label class="setting">
            <span>Match a sign-in by</span>
            <select aria-label="Match attribute" value={match} disabled={down || busy.value}
              onChange={(e) => void set({ on, match: (e.currentTarget as HTMLSelectElement).value as SCIMMatch })}>
              {(Object.keys(matchNames) as SCIMMatch[]).map((m) => <option key={m} value={m}>{matchNames[m]}</option>)}
            </select>
          </label>
          <p class="hint">The SCIM {match} must equal the sign-in’s {p.accountClaim ?? "sub"} claim. Map it so at the provider.</p>
          {made.value && (
            <div class="request" role="status">
              <span>Token {made.value.token.name}: <code>{made.value.value}</code> <CopyButton text={made.value.value} /></span>
              <span class="request-actions"><button type="button" onClick={() => { made.value = null; }}>Done</button></span>
              <p class="hint attention">Copy it now. It is not shown again.</p>
            </div>
          )}
          {tokens.value?.map((t) => (
            <div key={t.id} class="request">
              <span>{t.name}<span class="quiet small"> · {tokenWords(t)}</span></span>
              {!t.revoked && <span class="request-actions"><button type="button" class="link destructive" disabled={down || busy.value} onClick={() => revoke(t)}>Revoke…</button></span>}
            </div>
          ))}
          <form class="setting" onSubmit={(e) => { e.preventDefault(); make(); }}>
            <input type="text" placeholder="Okta provisioning" aria-label={`Token name for ${p.name}`} value={naming.value}
              onInput={(e) => { naming.value = (e.currentTarget as HTMLInputElement).value; }} />
            <button type="submit" disabled={down || busy.value || live.length >= 2}>Make Token</button>
          </form>
        </>
      )}
      <p class="hint">{scimFoot}</p>
    </div>
  );
}

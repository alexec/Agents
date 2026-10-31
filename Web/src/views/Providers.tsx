// Settings ▸ Machine providers (#1808), the window's Settings ▸ Machine Providers: each
// provider as a card of its workspaces, Add Provider… (kind first, then its short form), Edit…,
// List Again and Remove…, and on a workspace Link to Host…, Start, Stop and Unlink.
import { useEffect, useState } from "preact/hooks";
import type { ControlMachine, ProviderSummary, MachineInfo } from "../protocol/generated";
import type { Store } from "../model/store";
import {
  defaultIdleMinutes, idleChoices, kindChip, kindFields, kindNeeds, kindOfPreset, kindTitle, linkableHosts, mayBe, noHostLine,
  providerKinds, providerLine, providerRequest, providerWords as words, workspaceLine, type ProviderKind,
} from "../model/machineProviders";
import { Modal } from "./Modal";
import { MachineDialog } from "./MachineDialog";
import { makers } from "../model/machineFromRepository";
import { adminsOnly, providerLine as groupLine } from "../model/teamGroups";

const time = (at: Date) => at.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });

export function ProvidersSection({ store }: { store: Store }) {
  const providers = store.providers.list.value;
  const problem = store.providers.problem.value;
  const [adding, setAdding] = useState(false);
  const [editing, setEditing] = useState<ProviderSummary>();
  const [linking, setLinking] = useState<{ provider: ProviderSummary; workspace: MachineInfo }>();
  const [said, setSaid] = useState<string | null>(null);
  // Lists every provider again when the page opens (FR-004).
  useEffect(() => { void store.providers.load(); }, []);
  const oneCopy = problem === words.oneCopy;
  return (
    <section aria-labelledby="settings-providers">
      <h3 class="section-head" id="settings-providers">{words.heading}</h3>
      {problem && <p class={oneCopy ? "hint" : "hint failure"}>{problem}</p>}
      {said && <p class="hint failure">{said}</p>}
      {!oneCopy && providers?.map((p) => (
        <ProviderCard key={p.id} store={store} provider={p} say={setSaid} edit={() => setEditing(p)}
          link={(workspace) => setLinking({ provider: p, workspace })} />
      ))}
      {!oneCopy && (
        <>
          {/* Only an admin adds one (#1761). */}
          {store.person.value?.role !== "member" && (
            <div class="provider-add"><button type="button" onClick={() => setAdding(true)}>{words.add}</button></div>
          )}
          <p class="hint">{words.footer}</p>
        </>
      )}
      {(adding || editing) && (
        <AddProviderDialog store={store} editing={editing} close={() => { setAdding(false); setEditing(undefined); }} />
      )}
      {linking && (
        <LinkDialog store={store} provider={linking.provider} workspace={linking.workspace} close={() => setLinking(undefined)} />
      )}
    </section>
  );
}

function ProviderCard({ store, provider, say, edit, link }: {
  store: Store; provider: ProviderSummary; say: (why: string | null) => void; edit: () => void; link: (w: MachineInfo) => void;
}) {
  const hosts = store.hosts.value;
  const groups = store.providers.groups.value;
  const admin = store.person.value?.role !== "member";
  const line = [providerLine(provider, time), groupLine(provider, groups)].filter(Boolean).join(" · ");
  const [making, setMaking] = useState(false);
  const setGroup = async (group: string) => say(await store.providers.setGroup(provider.id, group || null));
  const remove = async () => {
    if (!window.confirm(`${words.removeTitle(provider.name)} ${words.removeNote}`)) return;
    say(await store.providers.remove(provider.id));
  };
  return (
    <ul class="setup-card list provider-card" aria-label={provider.name}>
      <li class="connection">
        <div class="grow">
          <p class="strong">{provider.name} <span class="chip">{kindChip(provider)}</span></p>
          {line && <p class="small quiet">{line}</p>}
        </div>
        {/* The same New Machine as Add a Machine…, at this provider (#2131). */}
        {makers([provider]).length > 0 && (
          <button type="button" onClick={() => setMaking(true)}>New Machine…</button>
        )}
        <button type="button" class="link small" onClick={() => void store.providers.refresh(provider.id)}>List Again</button>
        {/* Who may start machines from it (#1761): an admin gives it to a group. */}
        {admin && (
          <select aria-label={`${provider.name}’s group`} value={provider.group ?? ""}
            onChange={(e) => void setGroup((e.currentTarget as HTMLSelectElement).value)}>
            <option value="">{adminsOnly}</option>
            {groups.map((g) => <option key={g.id} value={g.id}>{g.name}</option>)}
          </select>
        )}
        {admin && kindOfPreset(provider.preset) && <button type="button" onClick={edit}>Edit…</button>}
        {admin && <button type="button" class="destructive" onClick={() => void remove()}>Remove…</button>}
      </li>
      {provider.workspaces.map((w) => (
        <WorkspaceRow key={w.id} store={store} provider={provider} workspace={w} hosts={hosts} say={say} link={() => link(w)} />
      ))}
      {making && <MachineDialog store={store} machine picked={provider.id} close={() => setMaking(false)} />}
    </ul>
  );
}

function WorkspaceRow({ store, provider, workspace, hosts, say, link }: {
  store: Store; provider: ProviderSummary; workspace: MachineInfo; hosts: readonly ControlMachine[];
  say: (why: string | null) => void; link: () => void;
}) {
  const host = workspace.host ? hosts.find((h) => h.id === workspace.host) : undefined;
  const linked = host?.workspace;
  const starting = store.hostsBeingStarted.value.includes(host?.id ?? "");
  const stop = async () => {
    if (!host) return;
    let answer = await store.providers.stop(host.id);
    if (answer && typeof answer === "object") {
      if (!window.confirm(answer.question)) return;
      answer = await store.providers.stop(host.id, true);
    }
    say(typeof answer === "string" ? answer : null);
  };
  const unlink = async () => {
    if (!host || !window.confirm(`Unlink ${host.name} from ${workspace.name}? ${provider.name} can no longer start or stop it.`)) return;
    say(await store.providers.unlink(host.id));
  };
  const free = linkableHosts(workspace, hosts);
  const noHost = noHostLine(workspace, hosts);
  return (
    <li class="connection workspace-row">
      <span class={`dot ${workspace.state === "running" ? "online" : workspace.state === "unknown" ? "attention" : "offline"}`} aria-hidden="true" />
      <div class="grow">
        <p>{workspace.name}</p>
        <p class="small quiet">{linked?.phase ?? workspaceLine(workspace, hosts)}</p>
        {noHost && <p class="small quiet">{noHost}</p>}
      </div>
      {host && linked?.canStart && (
        <button type="button" disabled={starting} onClick={() => void store.startHost(host.id)}>{starting ? "Starting…" : "Start"}</button>
      )}
      {host && linked?.canStop && <button type="button" onClick={() => void stop()}>Stop</button>}
      {host && <button type="button" class="link small" onClick={() => void unlink()}>Unlink</button>}
      {!workspace.host && free.length > 0 && (
        <button type="button" onClick={link}>
          {free.length === 1 && mayBe(workspace, free[0]!.name) ? `Link to ${free[0]!.name}…` : "Link to Machine…"}
        </button>
      )}
    </li>
  );
}

/** Add a Provider, or Edit… one. With `added` (Add a Machine, #2131) it goes on with the provider it added, in place of closing. */
export function AddProviderDialog({ store, editing, close, added }: {
  store: Store; editing?: ProviderSummary | undefined; close: () => void; added?: (id: string | undefined) => void;
}) {
  const [kind, setKind] = useState<ProviderKind | undefined>(kindOfPreset(editing?.preset));
  const [name, setName] = useState(editing?.name ?? "");
  // The values, secrets among them, live in this sheet's state only, and go when it closes.
  const [values, setValues] = useState<Record<string, string>>({});
  const [problem, setProblem] = useState<string>();
  const [working, setWorking] = useState(false);
  const fields = kind ? kindFields(kind).filter((f) => !editing || f.secret) : [];
  const shown = (id: string) => values[id] ?? fields.find((f) => f.id === id)?.value ?? "";
  const choose = (k: ProviderKind) => {
    setKind(k);
    setValues(Object.fromEntries(kindFields(k).filter((f) => f.value).map((f) => [f.id, f.value!])));
    setProblem(undefined);
  };
  const save = async () => {
    if (!kind) return;
    const request = providerRequest(kind, name, values, editing);
    if (typeof request === "string") return setProblem(request);
    setWorking(true);
    setProblem(undefined);
    const before = new Set((store.providers.list.peek() ?? []).map((p) => p.id));
    const refused = await store.providers.save(request);
    setWorking(false);
    if (refused) setProblem(refused);
    else if (added) added((store.providers.list.peek() ?? []).find((p) => !before.has(p.id))?.id);
    else close();
  };
  return (
    <Modal label={editing ? `Edit ${editing.name}` : "Add a Provider"} close={close}>
      <div class="sheet-body connect-sheet provider-sheet">
        <p class="strong">{editing ? `Edit ${editing.name}` : "Add a Provider"}</p>
        {!editing && (
          <div class="button-group" role="radiogroup" aria-label="Kind">
            {providerKinds.map((k) => (
              <button key={k} type="button" role="radio" aria-checked={kind === k} class={kind === k ? "on" : ""}
                disabled={working} onClick={() => choose(k)}>{kindTitle(k)}</button>
            ))}
          </div>
        )}
        {kind && (
          <form class="token-form" onSubmit={(e) => { e.preventDefault(); void save(); }}>
            <p class="small quiet">{kindNeeds(kind)}</p>
            <label>Name
              <input type="text" value={name} placeholder={kindTitle(kind)} disabled={working} autocomplete="off"
                onInput={(e) => setName((e.target as HTMLInputElement).value)} />
            </label>
            {fields.map((f) => (
              <label key={f.id}>{f.label}{f.optional ? " (optional)" : ""}
                {f.id === "serviceKey"
                  ? <textarea rows={4} value={shown(f.id)} disabled={working} autocomplete="off" spellcheck={false}
                      placeholder={editing ? words.editSecret : undefined}
                      onInput={(e) => setValues({ ...values, [f.id]: (e.target as HTMLTextAreaElement).value })} />
                  : f.secret
                  ? <input type="password" value={shown(f.id)} disabled={working} placeholder={editing ? words.editSecret : f.prompt}
                      autocomplete="new-password" onInput={(e) => setValues({ ...values, [f.id]: (e.target as HTMLInputElement).value })} />
                  : <input type="text" value={shown(f.id)} disabled={working} placeholder={f.prompt} autocomplete="off"
                      autocapitalize="off" spellcheck={false}
                      onInput={(e) => setValues({ ...values, [f.id]: (e.target as HTMLInputElement).value })} />}
              </label>
            ))}
          </form>
        )}
        {working && <p class="quiet small">Checking it lists its machines…</p>}
        {problem && <p class="small failure">{problem}</p>}
        <div class="sheet-actions">
          <span class="quiet small grow">{words.secretsFoot}</span>
          <button type="button" onClick={close}>Cancel</button>
          <button type="button" class="prominent" disabled={!kind || working} onClick={() => void save()}>{editing ? "Save" : "Add"}</button>
        </div>
      </div>
    </Modal>
  );
}

/** Link to Machine (#691 L5): a host that already runs on this workspace, with when to start and stop it. */
function LinkDialog({ store, provider, workspace, close }: {
  store: Store; provider: ProviderSummary; workspace: MachineInfo; close: () => void;
}) {
  const hosts = linkableHosts(workspace, store.hosts.value);
  const [host, setHost] = useState(hosts[0]?.id ?? "");
  const [startWhenUsed, setStartWhenUsed] = useState(true);
  const [idle, setIdle] = useState(defaultIdleMinutes);
  const [problem, setProblem] = useState<string | null>(null);
  const link = async () => {
    const refused = await store.providers.link(host, provider.id, workspace.id, startWhenUsed, idle);
    if (refused) setProblem(refused);
    else close();
  };
  return (
    <Modal label={`Link ${workspace.name} to a Machine`} close={close}>
      <div class="sheet-body connect-sheet provider-sheet">
        <p class="strong">Link {workspace.name} to a Machine</p>
        <p class="small quiet">Agents already runs on this machine: {provider.name} starts and stops it, and nothing is installed again.</p>
        {hosts.length === 0 ? <p class="small">{words.noHosts}</p> : (
          <form class="token-form" onSubmit={(e) => { e.preventDefault(); void link(); }}>
            <label>Machine
              <select value={host} onChange={(e) => setHost((e.target as HTMLSelectElement).value)}>
                {hosts.map((h) => <option key={h.id} value={h.id}>{h.name}</option>)}
              </select>
            </label>
            <label class="setting">
              <span>Start when used</span>
              <input type="checkbox" role="switch" checked={startWhenUsed} onChange={(e) => setStartWhenUsed(e.currentTarget.checked)} />
            </label>
            <label>Stop when idle
              <select value={String(idle)} onChange={(e) => setIdle(Number((e.target as HTMLSelectElement).value))}>
                {idleChoices.map((c) => <option key={c.minutes} value={String(c.minutes)}>{c.label}</option>)}
              </select>
            </label>
          </form>
        )}
        {problem && <p class="small failure">{problem}</p>}
        <div class="sheet-actions">
          <button type="button" onClick={close}>Cancel</button>
          <button type="button" class="prominent" disabled={!host} onClick={() => void link()}>Link</button>
        </div>
      </div>
    </Modal>
  );
}

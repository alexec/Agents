// Personas from a marketplace (#3665, #3678), as the Mac's AddPersonaSheet.swift: the personas
// added from a GitHub marketplace's `personas/` folder, each with **update** when its source moved
// on, **Update…** and **Remove…**; **Add persona…** searches a marketplace and shows the whole file
// before it goes in. A persona the person made is in the editor below, and this never touches it.
import { useEffect, useMemo, useState } from "preact/hooks";
import type {
  CatalogError, CatalogResult, ManagedPersona, Marketplace, PersonaPreview, PersonaUpdatePreviewAnswer,
  SkillDestination, UpdateState,
} from "../protocol/generated";
import type { Store } from "../model/store";
import {
  addAction, catalogError, catalogSentence, currentMarketplace, destinationNote, goesTo, hasUpdate,
  personaMarketplaces, settingWarning, sourceLine,
} from "../model/personaCatalog";
import { lineDiff } from "../model/diff";
import { hunkRows } from "../model/fileDiff";
import { fromWireDate } from "../protocol/dates";
import { Modal } from "./Modal";
import { FileDiff } from "./FileDiff";

/** The marketplace last searched for personas, kept across sheets, as the Mac's `catalog.personas.marketplace`. */
const chosenKey = "catalog.personas.marketplace";

export function MarketplacePersonasSection({ store, host, destination, down, changed }: {
  store: Store; host: string; destination: SkillDestination; down: boolean;
  /** Called after a persona was added, updated or removed, so the editor reads its files again. */
  changed: () => void;
}) {
  const [personas, setPersonas] = useState<ManagedPersona[]>([]);
  const [updates, setUpdates] = useState<Record<string, UpdateState>>({});
  const [adding, setAdding] = useState(false);
  const [updating, setUpdating] = useState<string | null>(null);
  const [failure, setFailure] = useState<string | null>(null);

  async function load() {
    const fresh = await store.link.call("personas/managed", { destination }, host).then((a) => a.personas, () => null);
    if (!fresh) return;
    setPersonas(fresh);
    // Nil when it could not be asked: no marks rather than wrong ones.
    if (fresh.length) {
      const marks = await store.link.call("personas/check-updates", { destination }, host).then((a) => a.updates, () => null);
      if (marks) setUpdates(marks);
    }
  }
  useEffect(() => { setPersonas([]); setUpdates({}); void load(); }, [host, destination.kind, destination.folder]);
  async function reload() { await load(); changed(); }

  async function remove(persona: ManagedPersona) {
    if (!confirm(`Move ${persona.id}.md to the Trash?\n\n${destination.kind === "personal"
      ? "New sessions can't pick it after that. You can take it back out of the Trash."
      : "New sessions in this folder can't pick it after that. The removal shows in the folder's changes, uncommitted."}`)) return;
    try {
      await store.link.call("personas/remove", { destination, name: persona.id }, host);
      setFailure(null);
      await reload();
    } catch (error) { setFailure(catalogSentence(catalogError(error))); }
  }

  return <div class="persona-catalog">
    <div class="persona-catalog-head">
      {personas.length > 0 && <h4>From a marketplace</h4>}
      <button type="button" disabled={down} onClick={() => setAdding(true)}>Add persona…</button>
    </div>
    {personas.map((persona) => {
      const update = hasUpdate(updates[persona.id]);
      return <div key={persona.id} class="persona-catalog-row" aria-label={persona.id}>
        <strong>{persona.id}</strong>
        {update && <span class="chip attention">update</span>}
        {persona.edited && <span class="chip">edited</span>}
        <span class="hint">{sourceLine(persona)}</span>
        <span class="spacer" />
        {update && <button type="button" class="prominent" disabled={down} onClick={() => setUpdating(persona.id)}>Update…</button>}
        <button type="button" disabled={down} onClick={() => void remove(persona)}>Remove…</button>
      </div>;
    })}
    {failure && <p class="failure" role="alert">{failure}</p>}
    {adding && <AddPersonaModal store={store} host={host} destination={destination}
      installed={new Set(personas.map((p) => p.id))} onAdded={() => void reload()} close={() => setAdding(false)} />}
    {updating && <UpdatePersonaModal store={store} host={host} destination={destination} id={updating}
      onUpdated={() => void reload()} close={() => setUpdating(null)} />}
  </div>;
}

/** A note above the file: grey, or tinted when it is a warning. */
function Note({ text, attention }: { text: string; attention: boolean }) {
  return <p class={`persona-note${attention ? " attention" : ""}`} role={attention ? "alert" : undefined}>{text}</p>;
}

/** Add a persona: choose a GitHub marketplace, search its `personas/` folder, and read the whole file first. */
export function AddPersonaModal({ store, host, destination, installed, onAdded, close }: {
  store: Store; host: string; destination: SkillDestination; installed: ReadonlySet<string>;
  onAdded: () => void; close: () => void;
}) {
  const [marketplaces, setMarketplaces] = useState<Marketplace[] | null>(null);
  const [chosen, setChosen] = useState(() => localStorage.getItem(chosenKey) ?? "provided:anthropic-skills");
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<CatalogResult[]>([]);
  const [searched, setSearched] = useState(false);
  const [searchError, setSearchError] = useState<CatalogError | null>(null);
  const [previewError, setPreviewError] = useState<CatalogError | null>(null);
  const [opening, setOpening] = useState<string | null>(null);
  const [preview, setPreview] = useState<PersonaPreview | null>(null);
  const [added, setAdded] = useState<ReadonlySet<string>>(installed);
  const marketplace = useMemo(() => marketplaces && currentMarketplace(marketplaces, chosen), [marketplaces, chosen]);

  useEffect(() => {
    void store.link.call("marketplaces/list", { kind: "skills", destination }, host)
      .then((a) => setMarketplaces(personaMarketplaces(a.marketplaces)), () => setMarketplaces([]));
  }, [host]);

  useEffect(() => {
    if (!marketplace) { setResults([]); setSearched(false); setSearchError(null); return; }
    let live = true;
    const timer = setTimeout(() => {
      void store.link.call("personas/search", { query: query.trim(), marketplace: marketplace.id, destination }, host)
        .catch((error: unknown) => ({ results: [], error: catalogError(error) }))
        .then((answer) => {
          if (!live) return;
          setResults(answer.results);
          setSearchError(answer.error ?? null);
          setPreviewError(null);
          setSearched(true);
        });
    }, 300);
    return () => { live = false; clearTimeout(timer); };
  }, [query, marketplace?.id]);

  function choose(id: string) {
    setChosen(id);
    localStorage.setItem(chosenKey, id);
  }

  async function open(result: CatalogResult) {
    if (opening) return;
    setOpening(result.id);
    setPreviewError(null);
    const answer = await store.link.call("personas/preview", { result, destination }, host)
      .catch((error: unknown) => ({ preview: undefined, error: catalogError(error) }));
    setOpening(null);
    if (answer.preview) setPreview(answer.preview);
    else setPreviewError(answer.error ?? { failed: { _0: "no answer" } });
  }

  return <Modal label="Add a persona" close={close}>
    <div class="sheet-body persona-sheet">
      {preview
        ? <PersonaPreviewPane store={store} host={host} preview={preview} destination={destination}
          back={() => setPreview(null)} close={close}
          added={(id) => { setAdded(new Set([...added, id])); setPreview(null); onAdded(); }} />
        : <>
          <div class="persona-sheet-head">
            <h2>Add a persona</h2>
            <span class="spacer" />
            <label class="inline">Marketplace{" "}
              <select value={marketplace?.id ?? ""} disabled={!marketplace} onChange={(e) => choose(e.currentTarget.value)}>
                {!marketplace && <option value="">None on</option>}
                {(marketplaces ?? []).filter((m) => m.enabled).map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}
              </select>
            </label>
            <span class="hint">{destination.kind === "personal" ? "Adds to ~/.agents" : "Adds to this folder"}</span>
          </div>
          <input type="search" aria-label="Search personas" placeholder={`Search ${marketplace?.name ?? "personas"}`}
            value={query} onInput={(e) => setQuery(e.currentTarget.value)} />
          <div class="persona-results">
            {marketplaces !== null && !marketplace
              ? <p class="hint">No GitHub marketplace is on. Manage Marketplaces in the Mac app adds or turns one on.</p>
              : searchError ? <p class="failure" role="alert">{catalogSentence(searchError)}</p>
                : previewError ? <p class="failure" role="alert">{catalogSentence(previewError)}</p>
                  : results.length === 0 && searched ? <p class="hint">No personas in its personas/ folder match.</p> : null}
            {results.map((result) => <button type="button" key={result.id} class="persona-result"
              aria-label={`${result.name}, ${result.owner}/${result.repo}${added.has(result.skillID) ? ", added" : ""}`}
              disabled={opening !== null} onClick={() => void open(result)}>
              <span><strong>{result.name}</strong>
                {result.known && <span class="chip">known</span>}
                {added.has(result.skillID) && <span class="chip">added</span>}
                {opening === result.id && <span class="hint"> Opening…</span>}</span>
              <code class="hint">{result.skillPath ?? `${result.owner}/${result.repo}`}</code>
            </button>)}
          </div>
          <div class="sheet-actions">
            <span class="hint">Personas are personas/&lt;id&gt;.md in a GitHub marketplace's repository. Choose one to read it before adding.</span>
            <button type="button" onClick={close}>Cancel</button>
          </div>
        </>}
    </div>
  </Modal>;
}

/** One persona before it goes in: where it is from, the commit, the settings it sets, and the whole file. */
function PersonaPreviewPane({ store, host, preview, destination, back, close, added }: {
  store: Store; host: string; preview: PersonaPreview; destination: SkillDestination;
  back: () => void; close: () => void; added: (id: string) => void;
}) {
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<CatalogError | null>(null);
  const action = addAction(preview);
  const settings = preview.persona.settings;
  const note = destinationNote(preview);
  const blocked = busy || preview.persona.problem !== undefined;

  async function add(replace: boolean) {
    if (replace && !confirm(`Replace ${preview.persona.id}?\n\nThe copy there now goes to the Trash.`)) return;
    setBusy(true);
    try {
      const answer = await store.link.call("personas/add", { previewID: preview.previewID, destination, replace }, host);
      added(answer.persona.id);
    } catch (error) { setFailure(catalogError(error)); } finally { setBusy(false); }
  }

  const commit = preview.committedAt
    ? `${preview.commit.slice(0, 7)} · ${fromWireDate(preview.committedAt).toLocaleDateString()}`
    : preview.commit.slice(0, 7);
  const facts: [string, string | undefined][] = [
    ["Owner", preview.result.owner], ["Repo", preview.result.repo], ["Commit", commit],
    ["Runtime", settings.runtimeID], ["Model", settings.model], ["Effort", settings.effort],
    ["Permission mode", settings.permissionMode], ["Goes to", goesTo(destination, preview.persona.id)],
  ];
  return <>
    <div class="persona-sheet-head">
      <button type="button" class="link" onClick={back}>‹ Results</button>
      <h2>{preview.persona.name}</h2>
    </div>
    <div class="persona-preview">
      <div>
        <dl class="persona-facts">
          {facts.map(([label, value]) => <div key={label}><dt>{label}</dt>
            <dd>{value === undefined ? <span class="hint">not set</span> : <code>{value}</code>}</dd></div>)}
        </dl>
        {failure && <Note text={catalogSentence(failure)} attention />}
        {preview.persona.problem && <Note attention
          text={`Its front matter can't be read (${preview.persona.problem}), so it can't be added.`} />}
        {note && <Note text={note.text} attention={note.attention} />}
      </div>
      <div class="persona-file">
        <code class="hint">{preview.path}</code>
        <pre>{preview.markdown}</pre>
      </div>
    </div>
    <div class="sheet-actions">
      <span class="hint">Taken from github.com/{preview.result.owner}/{preview.result.repo} at {preview.commit.slice(0, 7)}.</span>
      <button type="button" onClick={close}>Cancel</button>
      {action === "added" && <button type="button" disabled>Added</button>}
      {action === "replace" && <button type="button" class="prominent" disabled={blocked} onClick={() => void add(true)}>Replace</button>}
      {(action === "add" || action === "blocked") && <button type="button" class="prominent"
        disabled={blocked || action === "blocked"} onClick={() => void add(false)}>Add</button>}
    </div>
  </>;
}

/** Update a persona: its source at the current commit as a diff against the file there, with a warning
 * above it when the runtime or the permission mode changes. Nothing changes until the person says Update. */
export function UpdatePersonaModal({ store, host, destination, id, onUpdated, close }: {
  store: Store; host: string; destination: SkillDestination; id: string; onUpdated: () => void; close: () => void;
}) {
  const [answer, setAnswer] = useState<PersonaUpdatePreviewAnswer | null>(null);
  const [error, setError] = useState<CatalogError | null>(null);
  const [busy, setBusy] = useState(false);

  async function load() {
    setError(null);
    try { setAnswer(await store.link.call("personas/update-preview", { destination, name: id }, host)); }
    catch (failure) { setError(catalogError(failure)); }
  }
  useEffect(() => { void load(); }, [host, id]);

  async function update(fresh: PersonaUpdatePreviewAnswer) {
    if (fresh.edited && !confirm(`Your edits to ${id} will be lost.\n\n`
      + "The file there was changed since it was added. Updating puts it in the Trash and takes the new one.")) return;
    setBusy(true);
    try {
      await store.link.call("personas/add", { previewID: fresh.preview.previewID, destination, replace: true }, host);
      onUpdated();
      close();
    } catch (failure) { setError(catalogError(failure)); } finally { setBusy(false); }
  }

  const rows = useMemo(() => answer
    ? hunkRows([{ oldStart: 1, newStart: 1, lines: lineDiff(answer.installed, answer.preview.markdown) }]) : [],
  [answer]);
  return <Modal label={`Update ${id}`} close={close}>
    <div class="sheet-body persona-sheet">
      <h2>Update {id}</h2>
      {!answer && !error && <p class="hint">Fetching {id}…</p>}
      {answer && <>
        {answer.changes.map((change) => <Note key={change.key} text={settingWarning(change)} attention />)}
        {answer.edited && <Note attention
          text="You've edited this persona since it was added. Updating replaces your edits; the copy with them goes to the Trash." />}
      </>}
      {error && <Note text={catalogSentence(error)} attention />}
      {answer && <>
        {answer.preview.persona.problem && <Note attention
          text={`The new file's front matter can't be read (${answer.preview.persona.problem}), so it can't be taken.`} />}
        {answer.installed === answer.preview.markdown
          ? <p>The file is the same; only the commit moves on.</p>
          : <div class="persona-diff"><FileDiff rows={rows} /></div>}
      </>}
      <div class="sheet-actions">
        {answer && <span class="hint">From github.com/{answer.preview.result.owner}/{answer.preview.result.repo} at {answer.preview.commit.slice(0, 7)}.</span>}
        {!answer && error && <button type="button" onClick={() => void load()}>Try Again</button>}
        <button type="button" onClick={close}>Cancel</button>
        {answer && <button type="button" class="prominent" disabled={busy || answer.preview.persona.problem !== undefined}
          onClick={() => void update(answer)}>Update</button>}
      </div>
    </div>
  </Modal>;
}

// Settings ▸ Agent Runtimes ▸ Auto (#2658, Stories 3, 4 and 6): which runtimes Auto uses and in what order,
// and what each shared value is on each runtime. Kept on the Mac's host, which sends a change on to its
// machines; the same on every client. Listed in ./sections.ts.
import type { AutoField, AutoMapping, AutoSettings, NativeSetting, RuntimeStatus } from "../../protocol/generated";
import type { Store } from "../../model/store";
import { autoFields, cellOf, fieldWords, levelWords, levelsOf, mappedRuntimes, markWords, unavailableState } from "../../model/levels";

/** A runtime's state, as the Auto page says it. */
function stateWords(store: Store, host: string, status: RuntimeStatus | undefined): string {
  const unavailable = unavailableState(status);
  if (unavailable || !status) return unavailable ?? "Not installed";
  if (store.account(host, status.runtime.id)?.state === "needsSignIn") return "Not signed in";
  const row = store.runtimeAllowances.value[host]?.rows.find((r) => r.credentialKey.startsWith(`${status.runtime.id}:`) && r.accountID === undefined);
  if (row && "out" in row.state.status) return "Out";
  if (row && "rateLimited" in row.state.status) return "Rate limited";
  return "Available";
}

const same = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);

export function AgentRuntimesSection({ store, down }: { store: Store; down: boolean }) {
  const host = store.macHostID.value;
  const settings: AutoSettings = store.autoSettings.value[host] ?? { order: [], excluded: [], overrides: [] };
  const mappings = store.autoMappings.value[host];
  const listed = store.runtimes.value[host] ?? [];
  const order = mappedRuntimes(mappings).length ? mappedRuntimes(mappings) : listed.map((r) => r.runtime.id);
  const name = (id: string) => listed.find((r) => r.runtime.id === id)?.runtime.name ?? id;
  const save = (next: AutoSettings) => void store.setAutoSettings(host, next);
  const move = (id: string, step: number) => {
    const ids = [...order];
    const i = ids.indexOf(id);
    if (i < 0 || i + step < 0 || i + step >= ids.length) return;
    [ids[i], ids[i + step]] = [ids[i + step]!, ids[i]!];
    save({ ...settings, order: ids });
  };
  const include = (id: string, on: boolean) =>
    save({ ...settings, excluded: on ? settings.excluded.filter((x) => x !== id) : [...settings.excluded.filter((x) => x !== id), id] });
  const setCell = (runtimeID: string, field: AutoField, level: string, native: NativeSetting | undefined) => {
    const overrides = settings.overrides.filter((o) => !(o.runtimeID === runtimeID && o.field === field && o.level === level));
    save({ ...settings, overrides: native ? [...overrides, { runtimeID, field, level, native }] : overrides });
  };
  if (!mappings) {
    if (host) void store.loadAuto(host);
    return null;
  }
  return (
    <section aria-labelledby="settings-auto">
      <h3 class="section-head" id="settings-auto">Agent Runtimes ▸ Auto</h3>
      <h4 class="small">Runtimes</h4>
      <ol class="auto-runtimes">
        {order.map((id, i) => (
          <li key={id} class="setting">
            <label>
              <input type="checkbox" role="switch" disabled={down} checked={!settings.excluded.includes(id)}
                aria-label={`Include ${name(id)}`} onChange={(e) => include(id, e.currentTarget.checked)} />
              <span>{name(id)}</span> <span class="quiet small">{stateWords(store, host, listed.find((r) => r.runtime.id === id))}</span>
            </label>
            <span>
              <button type="button" class="link" disabled={down || i === 0} aria-label={`Move ${name(id)} up`} onClick={() => move(id, -1)}>↑</button>
              <button type="button" class="link" disabled={down || i === order.length - 1} aria-label={`Move ${name(id)} down`} onClick={() => move(id, 1)}>↓</button>
            </span>
          </li>
        ))}
      </ol>
      <p class="hint">Auto tries the included runtimes in this order, and starts the session on the first that can take it. A rate-limited one is tried last.</p>
      <h4 class="small">Mappings</h4>
      <p class="hint">What each value is on each runtime. Choose a cell to set one of the runtime’s own settings.</p>
      {autoFields.map((field) => (
        <div class="auto-table" key={field}>
          <table>
            <caption class="small">{fieldWords[field]}</caption>
            <thead><tr><th scope="col">Runtime</th>{levelsOf(field).map((l) => <th scope="col" key={l}>{levelWords(field, l)}</th>)}</tr></thead>
            <tbody>
              {order.map((id) => (
                <tr key={id}>
                  <th scope="row">{name(id)}</th>
                  {levelsOf(field).map((level) => (
                    <td key={level}>
                      <Cell cell={cellOf(mappings, id, field, level)} down={down} label={`${name(id)}, ${levelWords(field, level)}`}
                        choices={mappings.choices.filter((c) => c.runtimeID === id && c.field === field)}
                        set={(native) => setCell(id, field, level, native)} />
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ))}
    </section>
  );
}

function Cell({ cell, choices, set, down, label }: {
  cell: AutoMapping | undefined; choices: { native: NativeSetting; words: string }[];
  set: (native: NativeSetting | undefined) => void; down: boolean; label: string;
}) {
  if (!cell) return <span class="quiet">—</span>;
  const index = choices.findIndex((c) => same(c.native, cell.native));
  const mark = cell.mark === "notPossible" ? cell.note ?? ""
    : cell.note && !cell.note.startsWith(markWords[cell.mark]) ? `${markWords[cell.mark]}: ${cell.note}` : cell.note ?? markWords[cell.mark];
  return (
    <span class="auto-cell">
      {choices.length > 0 ? (
        <select aria-label={label} disabled={down} value={index < 0 ? "" : String(index)}
          onChange={(e) => {
            const picked = choices[Number((e.currentTarget as HTMLSelectElement).value)];
            if (picked) set(picked.native);
          }}>
          {index < 0 && <option value="" disabled>{cell.words}</option>}
          {/* The cell's own words for the setting in force; the runtime's for the rest. */}
          {choices.map((c, i) => <option key={i} value={String(i)}>{i === index ? cell.words : c.words}</option>)}
        </select>
      ) : <span>{cell.words}</span>}
      <span class={`small ${cell.mark === "dropped" ? "failure" : "quiet"}`}>{cell.mark === "dropped" ? "⚠︎ " : ""}{mark}</span>
      {cell.mark === "yours" && <button type="button" class="link small" disabled={down} onClick={() => set(undefined)}>Reset</button>}
    </span>
  );
}

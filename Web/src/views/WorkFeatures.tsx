// Work ▸ Features (#3269, spec 3265), as the window's WorkFeaturesPane: a row per feature:<name> label
// (forge/features on each machine) with its epic counts; opened, its open epics (forge/issues with the
// feature), each with its progress and its lead, and its issues with no epic. A row opens the issue's page.
import { signal } from "@preact/signals";
import type { ComponentChildren } from "preact";
import { useEffect } from "preact/hooks";
import type { ForgeFeature, ForgeItem } from "../protocol/generated";
import type { Store } from "../model/store";
import { describe } from "../model/errors";
import { errorWords, labelColor, noForgeHere, shortRef } from "../model/work";
import { forgeHosts } from "../model/workLists";
import {
  epicLead, epicProgressWords, featureCountWords, featureTitle, leadRowWords, mergeFeatures, noFeatures, nothingOpen, openedFeature,
} from "../model/workFeatures";
import { go } from "../route";

// The list's state lives for the tab, so Back from an epic's page finds it as it was left.
const features = signal<ForgeFeature[] | null>(null);
const errors = signal<string[]>([]);
const opened = signal<ReadonlySet<string>>(new Set());
const items = signal<Readonly<Record<string, { items: ForgeItem[]; errors: string[] }>>>({});
const asked = signal(0);
let read: string | undefined;

async function loadFeatures(store: Store) {
  const mine = asked.value;
  const hosts = forgeHosts(store);
  const key = `${mine} ${hosts.map((h) => h.id).join(",")}`;
  if (read === key && features.value !== null) return;
  read = key;
  features.value = null;
  errors.value = [];
  items.value = {};
  const got = await Promise.all(hosts.map(async (h) => {
    try {
      return { host: h, list: await store.link.call("forge/features", {}, h.id) };
    } catch (e) {
      return { host: h, list: { features: [], errors: [{ forge: "", message: describe(e) }] } };
    }
  }));
  if (asked.value !== mine) return;
  errors.value = got.flatMap(({ host, list }) => (list.errors ?? []).map((e) => errorWords(e, hosts.length > 1 ? host.name : undefined)));
  features.value = mergeFeatures(got.map(({ list }) => list.features));
  for (const name of opened.value) void readItems(store, name);
}

/** An opened feature's open issues from every machine. */
async function readItems(store: Store, name: string) {
  const mine = asked.value;
  const hosts = forgeHosts(store);
  const got = await Promise.all(hosts.map(async (h) => {
    const machine = hosts.length > 1 ? h.name : undefined;
    try {
      const list = await store.link.call("forge/issues", { state: "open", limit: 100, feature: name }, h.id);
      return { items: list.items, errors: (list.errors ?? []).map((e) => errorWords(e, machine)) };
    } catch (e) {
      return { items: [], errors: [machine ? `${machine}: ${describe(e)}` : describe(e)] };
    }
  }));
  if (asked.value !== mine) return;
  items.value = { ...items.value, [name.toLowerCase()]: { items: got.flatMap((g) => g.items), errors: got.flatMap((g) => g.errors) } };
}

function toggle(store: Store, name: string) {
  const key = name.toLowerCase();
  const next = new Set(opened.value);
  if (next.delete(key)) { opened.value = next; return; }
  next.add(key);
  opened.value = next;
  if (!items.value[key]) void readItems(store, name);
}

export function WorkFeatures({ store }: { store: Store }) {
  const hosts = forgeHosts(store);
  useEffect(() => { void loadFeatures(store); }, [asked.value, hosts.map((h) => h.id).join(",")]);
  const list = features.value;
  return (
    <div class="work-list">
      <div class="work-filters">
        <span class="quiet small">The feature:&lt;name&gt; labels on the epics.</span>
        <button type="button" class="link" onClick={() => { asked.value++; }}>Refresh</button>
      </div>
      {errors.value.map((e) => <p key={e} class="hint">{e}</p>)}
      {hosts.length === 0 ? <p class="hint">{noForgeHere}</p>
        : list === null ? <p class="hint">Loading…</p>
        : list.length === 0 ? <p class="hint">{noFeatures}</p>
        : (
          <ul class="work-rows">
            {list.map((f) => <FeatureRow key={f.name} store={store} feature={f} />)}
          </ul>
        )}
    </div>
  );
}

function FeatureRow({ store, feature }: { store: Store; feature: ForgeFeature }) {
  const key = feature.name.toLowerCase();
  const isOpen = opened.value.has(key);
  const read = items.value[key];
  const dot = labelColor(feature.color);
  const shown = read ? openedFeature(read.items) : undefined;
  const agents = Object.values(store.agents.value).flat();
  return (
    <li>
      <button type="button" class="work-feature-head" aria-expanded={isOpen} onClick={() => toggle(store, feature.name)}
        title={isOpen ? `Fold ${feature.name}` : `Show ${feature.name}'s open epics and issues`}>
        <span class="chevron" aria-hidden="true">{isOpen ? "▾" : "▸"}</span>
        {dot && <span class="dot" style={{ background: dot }} aria-hidden="true" />}
        <span class="work-title">{featureTitle(feature.name)}</span>
        <span class="counts small">{featureCountWords(feature)}</span>
      </button>
      {isOpen && (
        <div class="work-feature-open">
          {read?.errors.map((e) => <p key={e} class="hint">{e}</p>)}
          {!shown ? <p class="hint">Loading…</p>
            : shown.epics.length === 0 && shown.loose.length === 0 ? <p class="hint">{nothingOpen}</p>
            : (
              <>
                <ul class="work-feature-items">
                  {shown.epics.map((e) => {
                    const lead = epicLead(e.node, agents);
                    return (
                      <li key={e.node.ref}>
                        <ItemButton item={e}>
                          <span class="figures small" title="Sub-issues closed, of all">{epicProgressWords(e)}</span>
                          <span class={`lead small${lead?.state === "waitingOnUser" ? " attention" : ""}`}>{leadRowWords(lead?.state)}</span>
                        </ItemButton>
                      </li>
                    );
                  })}
                </ul>
                {shown.loose.length > 0 && (
                  <>
                    <h4 class="small">Issues with no epic</h4>
                    <ul class="work-feature-items">
                      {shown.loose.map((i) => (
                        <li key={i.node.ref}><ItemButton item={i}>{i.level && <span class="quiet small">{i.level}</span>}</ItemButton></li>
                      ))}
                    </ul>
                  </>
                )}
              </>
            )}
        </div>
      )}
    </li>
  );
}

function ItemButton({ item, children }: { item: ForgeItem; children?: ComponentChildren }) {
  return (
    <button type="button" class="work-feature-row" title={`Open ${shortRef(item.node.ref)}'s page`}
      onClick={() => go({ nav: "work", section: "issue", item: item.node.ref })}>
      <span class="work-ref">{shortRef(item.node.ref)}</span>
      <span class="name">{item.title}</span>
      {children}
    </button>
  );
}

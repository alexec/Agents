// Settings ▸ Groups (#1761, spec 736 FR-027, FR-028), as the window's and the Remote's Groups pane
// (Shared/UI/People/GroupsPane.swift): each group, its people and the machine providers it has.
// An admin makes, changes and removes groups; a member sees the groups they are in, read only. A
// group from an org provider's SCIM says so (#1002, FR-028), and only SCIM changes its members.
import { useSignal } from "@preact/signals";
import type { Store } from "../model/store";
import type { Group, PersonRow } from "../protocol/generated";
import { describe } from "../model/errors";
import { botWords, dollars, foot, groupBots, groupCapFoot, groupCapLine, members, providersOf, readCap, removeMessage, removeTitle, title } from "../model/teamGroups";
import { fromProvider, orgName } from "../model/signIn";
import { groupRoleFoot, groupRoleWords } from "../model/orgSignIn";
import { Modal } from "./Modal";

function GroupSheet({ store, group, people, close }: {
  store: Store; group: Group | null; people: readonly PersonRow[]; close: () => void;
}) {
  const name = useSignal(group?.name ?? "");
  const everyone = useSignal(group?.everyone ?? false);
  const named = useSignal<string[]>(group?.members ?? []);
  // What its bots may spend together in a day (#2074), as typed.
  const cap = useSignal(group?.caps?.dailyUSD ? dollars(group.caps.dailyUSD) : "");
  const problem = useSignal<string | null>(null);
  const busy = useSignal(false);
  const save = async () => {
    const entry = readCap(cap.value);
    if (entry.kind === "refused") {
      problem.value = entry.problem;
      return;
    }
    busy.value = true;
    try {
      // In the order People lists them.
      const chosen = everyone.value ? [] : people.map((p) => p.id).filter((id) => named.value.includes(id));
      await store.link.call("groups/set", {
        ...(group ? { id: group.id } : {}), name: name.value.trim(), everyone: everyone.value, members: chosen,
        caps: entry.kind === "dollars" ? { dailyUSD: entry.usd } : {},
      });
      close();
    } catch (error) {
      problem.value = describe(error);
    } finally {
      busy.value = false;
    }
  };
  const toggle = (id: string, on: boolean) => {
    named.value = on ? [...named.value.filter((m) => m !== id), id] : named.value.filter((m) => m !== id);
  };
  const heading = group ? `Edit ${group.name}` : "Make a Group";
  return (
    <Modal label={heading} close={close}>
      <form method="dialog" class="sheet-body" onSubmit={(e) => { e.preventDefault(); void save(); }}>
        <h2>{heading}</h2>
        <input type="text" aria-label="Name" placeholder="Platform" autofocus autocomplete="off" value={name.value}
          onInput={(e) => (name.value = (e.currentTarget as HTMLInputElement).value)} />
        <label class="setting">
          <span>Everyone</span>
          <input type="checkbox" checked={everyone.value}
            onChange={(e) => (everyone.value = (e.currentTarget as HTMLInputElement).checked)} />
        </label>
        <p class="sheet-note">Everyone takes in each person who joins later too.</p>
        <input type="text" aria-label="Daily cap" placeholder="No cap, or dollars a day" autocomplete="off" value={cap.value}
          onInput={(e) => (cap.value = (e.currentTarget as HTMLInputElement).value)} />
        <p class="sheet-note">{groupCapFoot}</p>
        {!everyone.value && (
          <fieldset class="group-people">
            <legend>People</legend>
            {people.map((p) => (
              <label key={p.id} class="setting">
                <span>{p.name}</span>
                <input type="checkbox" checked={named.value.includes(p.id)}
                  onChange={(e) => toggle(p.id, (e.currentTarget as HTMLInputElement).checked)} />
              </label>
            ))}
          </fieldset>
        )}
        {problem.value && <p class="sheet-note failure" role="alert">{problem.value}</p>}
        <div class="sheet-actions">
          <button type="button" onClick={close}>Cancel</button>
          <button type="submit" class="prominent" disabled={!name.value.trim() || busy.value}>{group ? "Save" : "Make Group"}</button>
        </div>
      </form>
    </Modal>
  );
}

export function GroupsSection({ store, down }: { store: Store; down: boolean }) {
  // The store's one people list and its groups (#2055), loaded on each connection and each change.
  const list = store.people.value;
  const people = list?.people ?? [];
  const admin = list?.admin ?? false;
  const failure = store.peopleFailure.value;
  const problem = failure ? describe(failure) : null;
  const editing = useSignal<{ group: Group | null } | null>(null);
  const setRole = async (group: Group, admin: boolean) => {
    if (admin && !window.confirm(`Make each person in ${group.name} an admin while they are in it? ${groupRoleFoot}`)) return;
    try {
      // The change comes back as control/groupsChanged.
      await store.link.call("groups/setRole", admin ? { group: group.id, role: "admin" } : { group: group.id });
    } catch (error) {
      store.say(describe(error));
    }
  };
  const remove = async (group: Group) => {
    if (!window.confirm(`${removeTitle(group)} ${removeMessage}`)) return;
    try {
      // The change comes back as control/groupsChanged.
      await store.link.call("groups/remove", { id: group.id });
    } catch (error) {
      store.say(describe(error));
    }
  };
  const shown = list ? store.providers.groups.value : null;
  // A member in no group has nothing to see here.
  if (shown && !admin && shown.length === 0) return null;
  const providers = store.providers.list.value ?? [];
  return (
    <section aria-labelledby="settings-groups">
      <h3 class="section-head" id="settings-groups">{title}</h3>
      {problem && <p class="hint">{problem}</p>}
      {!shown && !problem && <p class="hint">Loading…</p>}
      {shown && (
        <>
          <ul class="people-list">
            {shown.map((group) => (
              <li key={group.id} class="person">
                <div class="setting"><span class="person-name">{group.name}</span></div>
                {group.source && (
                  <div class="person-org">
                    <span class="quiet small">{fromProvider(orgName(group.source.scim, store.orgProviderNames.value))}</span>
                    {/* FR-020: a SCIM group can make its people admins; an admin marks it. */}
                    {admin
                      ? (
                        <label class="small">
                          <input type="checkbox" checked={group.role === "admin"} disabled={down}
                            onChange={(e) => void setRole(group, (e.currentTarget as HTMLInputElement).checked)} /> {groupRoleWords}
                        </label>
                      )
                      : group.role === "admin" && <span class="quiet small"> · {groupRoleWords}</span>}
                  </div>
                )}
                <div class="person-things">
                  <span class="faint small">People</span>
                  <span class="small">{members(group, people)}</span>
                  {/* Its bots apart from its people (#2132). */}
                  <span class="faint small">{botWords.title}</span>
                  <span class="small">{groupBots(group, people)}</span>
                  <span class="faint small">Machine providers</span>
                  <span class="small">{providersOf(group, providers) ?? "None"}</span>
                  <span class="faint small">Daily cap</span>
                  <span class="small">{groupCapLine(group, people)}</span>
                  {admin && (
                    <span>
                      <button type="button" class="link" disabled={down} onClick={() => { editing.value = { group }; }}>Edit…</button>
                      {" "}
                      <button type="button" class="link destructive" disabled={down} onClick={() => void remove(group)}>Remove…</button>
                    </span>
                  )}
                </div>
              </li>
            ))}
          </ul>
          {admin && (
            <button type="button" class="invite" disabled={down} onClick={() => { editing.value = { group: null }; }}>Make a Group…</button>
          )}
          <p class="hint">{foot(admin)}</p>
        </>
      )}
      {editing.value && (
        <GroupSheet store={store} group={editing.value.group} people={people.filter((p) => p.kind === "person")}
          close={() => { editing.value = null; }} />
      )}
    </section>
  );
}

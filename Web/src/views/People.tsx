// Settings ▸ People (#994, Team T1), as the window's and the Remote's People pane: each person with
// their role, their machines (name and state, nothing inside them) and their clients. An admin
// changes roles, invites a person with a one-use code, and removes a person; a member sees only
// themselves, read only. Machines waiting to join are at the top.
import { useEffect } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { Store } from "../model/store";
import type { PeopleList, PersonInvited, PersonRemovePreview, PersonRow, UserRole } from "../protocol/generated";
import { CallFailed } from "../wire/link";
import { describe, methodNotFound } from "../model/errors";
import { askingLine, badges, canRemove, joinCommandNote, joinCommandTitle, canSetRole, clientLine, inviteNote, machineLine, memberNote, noPeople, ordered, removeLines,
  removeTitle, roleNote, roleWord, roles, rotateFoot, rotateMessage, rotateTitle, rotated } from "../model/people";
import { JoinRequests } from "./JoinRequest";
import { Modal } from "./Modal";

function sentence(error: unknown): string {
  // A control plane before #994 knows one person and no list.
  if (error instanceof CallFailed && error.code === methodNotFound) return "This control plane knows only you. Update it to add people.";
  return describe(error);
}

function InviteSheet({ store, close }: { store: Store; close: () => void }) {
  const name = useSignal("");
  const role = useSignal<UserRole>("member");
  const invited = useSignal<PersonInvited | null>(null);
  const problem = useSignal<string | null>(null);
  const busy = useSignal(false);
  const copied = useSignal(false);
  const invite = async () => {
    busy.value = true;
    try {
      invited.value = await store.link.call("people/invite", { name: name.value.trim(), role: role.value });
      problem.value = null;
    } catch (error) {
      problem.value = sentence(error);
    } finally {
      busy.value = false;
    }
  };
  const copy = () => {
    const text = invited.value?.text;
    if (!text) return;
    void navigator.clipboard?.writeText(text).then(() => { copied.value = true; }).catch(() => {});
  };
  const shown = invited.value;
  return (
    <Modal label="Invite a Person" close={close}>
      {shown ? (
        <div class="sheet-body invite-code">
          <h2>Invite code for {shown.name}</h2>
          <code class="code-text" aria-label="Invite code">{shown.text}</code>
          <p class="sheet-note">{inviteNote(shown)}</p>
          <div class="sheet-actions">
            <button type="button" onClick={copy}>{copied.value ? "Copied" : "Copy"}</button>
            <button type="button" class="prominent" onClick={close}>Done</button>
          </div>
        </div>
      ) : (
        <form method="dialog" class="sheet-body" onSubmit={(e) => { e.preventDefault(); void invite(); }}>
          <h2>Invite a Person</h2>
          <input type="text" aria-label="Name" placeholder="Name" autofocus autocomplete="off" value={name.value}
            onInput={(e) => (name.value = (e.currentTarget as HTMLInputElement).value)} />
          <select aria-label="Role" value={role.value} onChange={(e) => (role.value = (e.currentTarget as HTMLSelectElement).value as UserRole)}>
            {roles.map((r) => <option key={r} value={r}>{roleWord(r)}</option>)}
          </select>
          <p class="sheet-note">{roleNote(role.value)}</p>
          {problem.value && <p class="sheet-note failure" role="alert">{problem.value}</p>}
          <div class="sheet-actions">
            <button type="button" onClick={close}>Cancel</button>
            <button type="submit" class="prominent" disabled={!name.value.trim() || busy.value}>Invite</button>
          </div>
        </form>
      )}
    </Modal>
  );
}

function RemoveSheet({ store, person, close }: { store: Store; person: PersonRow; close: () => void }) {
  const problem = useSignal<string | null>(null);
  const busy = useSignal(false);
  // What Remove would take (#1763), asked first; null from a control plane from before it.
  const preview = useSignal<PersonRemovePreview | null>(null);
  const asking = useSignal(true);
  useEffect(() => {
    let live = true;
    store.link.call("people/removePreview", { user: person.id })
      .then((answer) => { if (live) preview.value = answer; })
      .catch((error) => {
        if (live && !(error instanceof CallFailed && error.code === methodNotFound)) problem.value = sentence(error);
      })
      .finally(() => { if (live) asking.value = false; });
    return () => { live = false; };
  }, [person.id]);
  const remove = async () => {
    busy.value = true;
    try {
      await store.link.call("people/remove", { user: person.id });
      close();
    } catch (error) {
      problem.value = sentence(error);
    } finally {
      busy.value = false;
    }
  };
  return (
    <Modal label={removeTitle(person.name)} close={close}>
      <div class="sheet-body">
        <h2>{removeTitle(person.name)}</h2>
        {asking.value
          ? <p class="sheet-note" role="status">{askingLine(person.name)}</p>
          : <ul class="sheet-note remove-lines">{removeLines(person, preview.value).map((line) => <li key={line}>{line}</li>)}</ul>}
        {problem.value && <p class="sheet-note failure" role="alert">{problem.value}</p>}
        <div class="sheet-actions">
          <button type="button" onClick={close}>Cancel</button>
          <button type="button" class="prominent destructive" disabled={busy.value || asking.value} onClick={() => void remove()}>Remove</button>
        </div>
      </div>
    </Modal>
  );
}

/** Rotate Control Key… (#997): this page's own connection closes a moment later, and it takes the new key as it connects again. */
function RotateSheet({ store, close, done }: { store: Store; close: () => void; done: () => void }) {
  const problem = useSignal<string | null>(null);
  const busy = useSignal(false);
  const rotate = async () => {
    busy.value = true;
    try {
      await store.link.call("control/rotate", {});
      done();
      close();
    } catch (error) {
      problem.value = sentence(error);
    } finally {
      busy.value = false;
    }
  };
  return (
    <Modal label={rotateTitle} close={close}>
      <div class="sheet-body">
        <h2>{rotateTitle}</h2>
        <p class="sheet-note">{rotateMessage}</p>
        {problem.value && <p class="sheet-note failure" role="alert">{problem.value}</p>}
        <div class="sheet-actions">
          <button type="button" onClick={close}>Cancel</button>
          <button type="button" class="prominent" disabled={busy.value} onClick={() => void rotate()}>Rotate</button>
        </div>
      </div>
    </Modal>
  );
}

/** The one line a server runs to ask to join as you, with no code, and Copy (#994). */
function JoinCommand({ command }: { command: string }) {
  const copied = useSignal(false);
  const copy = () => void navigator.clipboard?.writeText(command).then(() => { copied.value = true; }).catch(() => {});
  return (
    <div class="join-command">
      <span class="faint small">{joinCommandTitle}</span>
      <div class="join-command-line">
        <code class="code-text" aria-label={joinCommandTitle}>{command}</code>
        <button type="button" onClick={copy}>{copied.value ? "Copied" : "Copy"}</button>
      </div>
      <span class="quiet small">{joinCommandNote}</span>
    </div>
  );
}

function PersonItem({ person, list, joinCommand, setRole, askRemove }: {
  person: PersonRow; list: PeopleList; joinCommand: string | null; setRole: (role: UserRole) => void; askRemove: () => void;
}) {
  const marks = badges(person);
  return (
    <li class="person">
      <div class="setting">
        <span class="person-name">
          {person.name}
          {marks.map((mark) => <span key={mark} class="badge">{mark}</span>)}
        </span>
        {canSetRole(person, list.people, list.admin) ? (
          <select aria-label={`${person.name}’s role`} value={person.role}
            onChange={(e) => setRole((e.currentTarget as HTMLSelectElement).value as UserRole)}>
            {roles.map((r) => <option key={r} value={r}>{roleWord(r)}</option>)}
          </select>
        ) : <span class="quiet small">{roleWord(person.role)}</span>}
      </div>
      <div class="person-things">
        <span class="faint small">Machines</span>
        {person.machines.length === 0 ? <span class="quiet small">None</span>
          : person.machines.map((m) => <span key={m.id} class="small">{machineLine(m)}</span>)}
        <span class="faint small">Clients</span>
        {person.clients.length === 0 ? <span class="quiet small">None</span>
          : person.clients.map((c) => <span key={c.id} class="small">{clientLine(c)}</span>)}
        {person.you && joinCommand && <JoinCommand command={joinCommand} />}
        {canRemove(person, list.admin) && (
          <button type="button" class="link destructive" onClick={askRemove}>Remove…</button>
        )}
      </div>
    </li>
  );
}

export function PeopleSection({ store, down }: { store: Store; down: boolean }) {
  const list = useSignal<PeopleList | null>(null);
  const problem = useSignal<string | null>(null);
  const inviting = useSignal(false);
  const removing = useSignal<PersonRow | null>(null);
  const rotating = useSignal(false);
  const wasRotated = useSignal(false);
  const load = async () => {
    try {
      list.value = await store.link.call("people/list", {});
      problem.value = null;
    } catch (error) {
      problem.value = sentence(error);
    }
  };
  // Again on each control/peopleChanged, and on each connection.
  const changes = store.peopleChanges.value;
  useEffect(() => { if (!down) void load(); }, [changes, down]);
  const setRole = async (person: PersonRow, role: UserRole) => {
    try {
      await store.link.call("people/setRole", { user: person.id, role });
    } catch (error) {
      store.say(sentence(error));
    }
    await load();
  };
  const shown = list.value;
  return (
    <section aria-labelledby="settings-people">
      <h3 class="section-head" id="settings-people">People</h3>
      <JoinRequests store={store} down={down} explained />
      {problem.value && <p class="hint">{problem.value}</p>}
      {!shown && !problem.value && <p class="hint">Loading…</p>}
      {shown && (
        <>
          {shown.people.length === 0 && <p class="hint">{noPeople}</p>}
          <ul class="people-list">
            {ordered(shown.people).map((person) => (
              <PersonItem key={person.id} person={person} list={shown} joinCommand={store.joinCommand.value}
                setRole={(role) => void setRole(person, role)} askRemove={() => { removing.value = person; }} />
            ))}
          </ul>
          {shown.admin
            ? <button type="button" class="invite" disabled={down} onClick={() => { inviting.value = true; }}>Invite a Person…</button>
            : <p class="hint">{memberNote}</p>}
          {shown.admin && (
            <div class="rotate-key">
              <button type="button" disabled={down} onClick={() => { rotating.value = true; }}>Rotate Control Key…</button>
              {wasRotated.value && <p class="hint" role="status">{rotated}</p>}
              <p class="hint">{rotateFoot}</p>
            </div>
          )}
        </>
      )}
      {rotating.value && <RotateSheet store={store} close={() => { rotating.value = false; }} done={() => { wasRotated.value = true; }} />}
      {inviting.value && <InviteSheet store={store} close={() => { inviting.value = false; void load(); }} />}
      {removing.value && <RemoveSheet store={store} person={removing.value} close={() => { removing.value = null; void load(); }} />}
    </section>
  );
}

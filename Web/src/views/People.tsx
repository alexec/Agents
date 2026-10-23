// Settings ▸ People (#994, Team T1), as the window's and the Remote's People pane: each person with
// their role, their machines (name and state, nothing inside them) and their clients. An admin
// changes roles, invites a person with a one-use code, and removes a person; a member sees only
// themselves, read only. Machines waiting to join are at the top. Settings ▸ Bots (#2132) is the same list of the
// bots alone, with Make a Bot… and the bots stopped at a cap. What an organisation's provider controls
// (#1002, FR-028) is said under each person in grey: Managed by, Waiting for first sign-in, Suspended
// by, and Set by on a role, which only the provider changes then.
import { useEffect } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { Store } from "../model/store";
import type { ControlCodeShown, Group, PeopleList, PersonInvited, PersonRemovePreview, PersonRow, UserRole } from "../protocol/generated";
import { botLine, botWords, capReachedWords, dollars, readCap } from "../model/teamGroups";
import { CallFailed } from "../wire/link";
import { describe, methodNotFound } from "../model/errors";
import { editInConsole } from "../model/orgPolicy";
import { go, route } from "../route";
import { askingLine, badges, checkFailedLine, canRemove, orgLines, providerManaged, roleSetBy, joinCommandNote, joinCommandTitle, canSetRole, clientLine, inviteNote, machineLine, memberNote, noPeople, ordered, removeLines,
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

export function RemoveSheet({ store, person, close }: { store: Store; person: PersonRow; close: () => void }) {
  const problem = useSignal<string | null>(null);
  const busy = useSignal(false);
  // What Remove would take (#1763), asked first; null from a control plane from before it.
  const preview = useSignal<PersonRemovePreview | null>(null);
  const asking = useSignal(true);
  // A check that failed, but for a control plane from before it, keeps Remove off (#2193).
  const checkProblem = useSignal<string | null>(null);
  const tries = useSignal(0);
  useEffect(() => {
    let live = true;
    asking.value = true;
    checkProblem.value = null;
    store.link.call("people/removePreview", { user: person.id })
      .then((answer) => { if (live) preview.value = answer; })
      .catch((error) => {
        if (live && !(error instanceof CallFailed && error.code === methodNotFound)) {
          checkProblem.value = checkFailedLine(person.name, sentence(error));
        }
      })
      .finally(() => { if (live) asking.value = false; });
    return () => { live = false; };
  }, [person.id, tries.value]);
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
        {checkProblem.value && !asking.value && (
          <p class="sheet-note failure" role="alert">
            {checkProblem.value} <button type="button" class="link" onClick={() => { tries.value++; }}>Try Again</button>
          </p>
        )}
        {problem.value && <p class="sheet-note failure" role="alert">{problem.value}</p>}
        <div class="sheet-actions">
          <button type="button" onClick={close}>Cancel</button>
          <button type="button" class="prominent destructive" disabled={busy.value || asking.value || checkProblem.value !== null}
            onClick={() => void remove()}>Remove</button>
        </div>
      </div>
    </Modal>
  );
}

/** Make a Bot… and Group and Cap… (#1761): a bot's name (when it is made), its group and daily cap. */
export function BotSheet({ store, bot, groups, close }: { store: Store; bot: PersonRow | null; groups: readonly Group[]; close: () => void }) {
  const name = useSignal("");
  // With one group, a new bot is in it.
  const group = useSignal(bot?.group ?? (groups.length === 1 ? groups[0]!.id : ""));
  const cap = useSignal(bot?.caps?.dailyUSD ? dollars(bot.caps.dailyUSD) : "");
  const problem = useSignal<string | null>(null);
  const busy = useSignal(false);
  const ready = (bot !== null || name.value.trim() !== "") && group.value !== "" && !busy.value;
  const save = async () => {
    const entry = readCap(cap.value);
    if (entry.kind === "refused") {
      problem.value = entry.problem;
      return;
    }
    busy.value = true;
    const caps = entry.kind === "dollars" ? { dailyUSD: entry.usd } : {};
    try {
      if (bot) await store.link.call("bots/setCaps", { user: bot.id, caps, group: group.value });
      else await store.link.call("bots/make", { name: name.value.trim(), group: group.value, caps });
      close();
    } catch (error) {
      problem.value = sentence(error);
    } finally {
      busy.value = false;
    }
  };
  const heading = bot ? `${bot.name}’s Group and Cap` : "Make a Bot";
  return (
    <Modal label={heading} close={close}>
      <form method="dialog" class="sheet-body" onSubmit={(e) => { e.preventDefault(); if (ready) void save(); }}>
        <h2>{heading}</h2>
        {!bot && (
          <input type="text" aria-label="Name" placeholder="review-bot" autofocus autocomplete="off" value={name.value}
            onInput={(e) => (name.value = (e.currentTarget as HTMLInputElement).value)} />
        )}
        <select aria-label="Group" value={group.value} onChange={(e) => (group.value = (e.currentTarget as HTMLSelectElement).value)}>
          {group.value === "" && <option value="">Choose a group…</option>}
          {groups.map((g) => <option key={g.id} value={g.id}>{g.name}</option>)}
        </select>
        <input type="text" aria-label="Daily cap" placeholder="No cap, or dollars a day" autocomplete="off" value={cap.value}
          onInput={(e) => (cap.value = (e.currentTarget as HTMLInputElement).value)} />
        <p class="sheet-note">{groups.length === 0 ? "Make a group first: a bot belongs to one." : botWords.foot}</p>
        {problem.value && <p class="sheet-note failure" role="alert">{problem.value}</p>}
        <div class="sheet-actions">
          <button type="button" onClick={close}>Cancel</button>
          <button type="submit" class="prominent" disabled={!ready}>{bot ? "Save" : "Make Bot"}</button>
        </div>
      </form>
    </Modal>
  );
}

/** Add a Machine… for a bot (#1761): the one line to run on the machine, which joins as the bot's. */
function BotMachineSheet({ store, bot, close }: { store: Store; bot: PersonRow; close: () => void }) {
  const shown = useSignal<ControlCodeShown | null>(null);
  const problem = useSignal<string | null>(null);
  const copied = useSignal(false);
  useEffect(() => {
    store.link.call("hosts/startEnroll", { as: bot.id })
      .then((code) => { shown.value = code; })
      .catch((error) => { problem.value = sentence(error); });
  }, [bot.id]);
  const line = shown.value ? shown.value.command ?? shown.value.text : null;
  const copy = () => { if (line) void navigator.clipboard?.writeText(line).then(() => { copied.value = true; }).catch(() => {}); };
  return (
    <Modal label={`A Machine for ${bot.name}`} close={close}>
      <div class="sheet-body invite-code">
        <h2>A Machine for {bot.name}</h2>
        {line ? <code class="code-text" aria-label="Command">{line}</code> : !problem.value && <p class="sheet-note" role="status">Making a code…</p>}
        <p class="sheet-note">{botWords.machineFoot}</p>
        {problem.value && <p class="sheet-note failure" role="alert">{problem.value}</p>}
        <div class="sheet-actions">
          {line && <button type="button" onClick={copy}>{copied.value ? "Copied" : "Copy"}</button>}
          <button type="button" class="prominent" onClick={close}>Done</button>
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

function PersonItem({ person, list, groups, names, joinCommand, setRole, askRemove, setCap, addMachine }: {
  person: PersonRow; list: PeopleList; groups: readonly Group[]; names: Readonly<Record<string, string>>; joinCommand: string | null;
  setRole: (role: UserRole) => void; askRemove: () => void; setCap: () => void; addMachine: () => void;
}) {
  const bot = person.kind === "bot";
  const marks = badges(person);
  const lines = orgLines(person, names);
  const setBy = roleSetBy(person, groups, names);
  // In the Console it is open already.
  const editHere = list.admin && providerManaged(person) && route.value.app !== "console";
  return (
    <li class="person">
      <div class="setting">
        <span class="person-name">
          {person.name}
          {marks.map((mark) => <span key={mark} class="badge">{mark}</span>)}
        </span>
        {/* A role a provider's group gives is read only, and says so (FR-020). */}
        {bot ? null : canSetRole(person, list.people, list.admin) ? (
          <select aria-label={`${person.name}’s role`} value={person.role}
            onChange={(e) => setRole((e.currentTarget as HTMLSelectElement).value as UserRole)}>
            {roles.map((r) => <option key={r} value={r}>{roleWord(r)}</option>)}
          </select>
        ) : <span class="quiet small">{setBy ? `${roleWord(person.role)} · ${setBy}` : roleWord(person.role)}</span>}
      </div>
      {(lines.length > 0 || editHere) && (
        <div class="person-org">
          {lines.map((line) => <span key={line} class="quiet small">{line}</span>)}
          {editHere && (
            <button type="button" class="link" onClick={() => go({ app: "console", section: "people" })}>{editInConsole}</button>
          )}
        </div>
      )}
      <div class="person-things">
        <span class="faint small">Machines</span>
        {person.machines.length === 0 ? <span class="quiet small">None</span>
          : person.machines.map((m) => <span key={m.id} class="small">{machineLine(m)}</span>)}
        {bot ? (
          <>
            {/* A bot has no role, clients or sign-in: its group, cap and spend (#1761). */}
            <span class="faint small">Group and cap</span>
            <span class="small">{botLine(person, groups)}</span>
            {list.admin && (
              <span>
                <button type="button" class="link" onClick={setCap}>{botWords.setCap}</button>{" "}
                <button type="button" class="link" onClick={addMachine}>{botWords.addMachine}</button>
              </span>
            )}
          </>
        ) : (
          <>
            <span class="faint small">Clients</span>
            {person.clients.length === 0 ? <span class="quiet small">None</span>
              : person.clients.map((c) => <span key={c.id} class="small">{clientLine(c)}</span>)}
          </>
        )}
        {person.you && joinCommand && <JoinCommand command={joinCommand} />}
        {canRemove(person, list.admin) && (
          <button type="button" class="link destructive" onClick={askRemove}>Remove…</button>
        )}
      </div>
    </li>
  );
}

/** Settings ▸ People: the people alone (#2132). */
export function PeopleSection({ store, down }: { store: Store; down: boolean }) {
  return <PeopleOrBots store={store} down={down} kind="person" />;
}

/** Settings ▸ Bots (#2132): the bots alone, an admin's. */
export function BotsSection({ store, down }: { store: Store; down: boolean }) {
  return <PeopleOrBots store={store} down={down} kind="bot" />;
}

function PeopleOrBots({ store, down, kind }: { store: Store; down: boolean; kind: "person" | "bot" }) {
  const problem = useSignal<string | null>(null);
  const inviting = useSignal(false);
  const removing = useSignal<PersonRow | null>(null);
  const rotating = useSignal(false);
  const wasRotated = useSignal(false);
  const botSheet = useSignal<{ bot: PersonRow | null } | null>(null);
  const machineFor = useSignal<PersonRow | null>(null);
  // The store's one list (#2055), loaded on each connection and each control/peopleChanged. A control plane
  // before groups has none: no bot can be made.
  const groups = store.providers.groups.value;
  const failure = store.peopleFailure.value;
  const said = problem.value ?? (failure ? sentence(failure) : null);
  const setRole = async (person: PersonRow, role: UserRole) => {
    try {
      // The change comes back as control/peopleChanged.
      await store.link.call("people/setRole", { user: person.id, role });
      problem.value = null;
    } catch (error) {
      store.say(sentence(error));
    }
  };
  const shown = store.people.value;
  const bots = kind === "bot";
  const rows = (shown?.people ?? []).filter((person) => (person.kind === "bot") === bots);
  const headId = bots ? "settings-bots" : "settings-people";
  return (
    <section aria-labelledby={headId}>
      <h3 class="section-head" id={headId}>{bots ? botWords.title : "People"}</h3>
      {!bots && <JoinRequests store={store} down={down} explained />}
      {said && <p class="hint">{said}</p>}
      {/* Each bot stopped at a cap, while it is true (#2073). */}
      {bots && shown?.admin && store.capped.value.map((reached) => (
        <p key={reached.user} class="hint attention" role="status">{capReachedWords(reached)}</p>
      ))}
      {!shown && !said && <p class="hint">Loading…</p>}
      {shown && (
        <>
          {rows.length === 0 && <p class="hint">{bots ? botWords.empty : noPeople}</p>}
          <ul class="people-list">
            {ordered(rows).map((person) => (
              <PersonItem key={person.id} person={person} list={shown} groups={groups} names={store.orgProviderNames.value} joinCommand={store.joinCommand.value}
                setRole={(role) => void setRole(person, role)} askRemove={() => { removing.value = person; }}
                setCap={() => { botSheet.value = { bot: person }; }} addMachine={() => { machineFor.value = person; }} />
            ))}
          </ul>
          {bots
            // A bot runs the team's workflows (#1761).
            ? shown.admin && (
              <>
                <button type="button" class="invite" disabled={down} onClick={() => { botSheet.value = { bot: null }; }}>{botWords.make}</button>
                <p class="hint">{botWords.foot}</p>
              </>
            )
            : shown.admin
              ? <button type="button" class="invite" disabled={down} onClick={() => { inviting.value = true; }}>Invite a Person…</button>
              : <p class="hint">{memberNote}</p>}
          {!bots && shown.admin && (
            <div class="rotate-key">
              <button type="button" disabled={down} onClick={() => { rotating.value = true; }}>Rotate Control Key…</button>
              {wasRotated.value && <p class="hint" role="status">{rotated}</p>}
              <p class="hint">{rotateFoot}</p>
            </div>
          )}
        </>
      )}
      {rotating.value && <RotateSheet store={store} close={() => { rotating.value = false; }} done={() => { wasRotated.value = true; }} />}
      {botSheet.value && (
        <BotSheet store={store} bot={botSheet.value.bot} groups={groups} close={() => { botSheet.value = null; }} />
      )}
      {machineFor.value && <BotMachineSheet store={store} bot={machineFor.value} close={() => { machineFor.value = null; }} />}
      {inviting.value && <InviteSheet store={store} close={() => { inviting.value = false; }} />}
      {removing.value && <RemoveSheet store={store} person={removing.value} close={() => { removing.value = null; }} />}
    </section>
  );
}

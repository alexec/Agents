# Research: Prompt Controls, Project Navigation, Scroll-to-Bottom, Remembered Mode, and Unseen File Requests

**Date**: 2026-09-19 | **Feature**: [spec.md](./spec.md)

Seven bugs. The first turned out to be six of its own. The second is two lines of existing code that cannot
be reached. The third needs nothing built that is not already there, the fourth is smaller than
it sounds, the fifth is one line in a binding, and the sixth looked like it needed a daemon
record and turned out not to. The seventh is a picker that should have been what the view
beside it already is. This is what was found by reading the code and by
measuring the row that goes missing.

## 1. Why the controls under the prompt disappear

`PromptBar.options` (`App/Sources/Chat/PromptBar.swift:526`) is an `if` with no `else`:

```swift
let shown = agent?.advertisedOptions.filter(\.isRenderable).sorted { ... } ?? model.draftOptions
if model.isLoadingDraftOptions { ...asking... }
else if !shown.isEmpty { ...the row... }
```

When `shown` is empty and nothing is loading, the view produces no content and the `VStack`
above it closes up. There is no state in which it says why. Five separate upstream causes can
put it in that state, and they are not variations of one bug.

### Cause 1 — Cursor advertises no options at all

**Decision**: This is the largest single cause and it is not a defect anywhere upstream.

`Tests/AgentsKitTests/Live/LiveRuntimeTests.swift:41` records it against the running runtimes:

> Options are a thing a runtime may offer, not a thing every runtime has. Three of them send
> `configOptions` and Cursor sends none at all: it puts its models and modes on the
> `session/new` result, which we do not decode for anyone, because those shapes disagree
> between runtimes and are leaving the protocol.

So one of the four runtimes in `RuntimeCatalog.builtIn` — Claude, Grok, Copilot, Cursor —
produces an empty row *every time, by design*. "Does not always show the controls" is, a
quarter of the time, exactly correct behaviour with no explanation attached to it.

**Rationale**: Nothing should be invented for Cursor. The fix is to say so.

**Alternatives considered**: Decoding Cursor's own `session/new` shape. Rejected for the reason
the live test already gives — those fields disagree between runtimes and are being retired
from the protocol. Feature 003 exists because reading them strictly cost whole sessions.

### Cause 2 — `??` cannot fire on an empty array

`agent?.advertisedOptions.filter(...) ?? model.draftOptions` falls back to the draft only when
there is **no agent**. Once an agent exists the left side is a non-nil empty array and the
coalesce never runs. More importantly there is no path anywhere that fetches options for an
agent that has none: `loadDraftOptions` is guarded by `draftRuntimeID`/`draftCwd` and
`prepare()` returns immediately unless `isNew`.

**Decision**: An agent with no advertised options must be able to ask for them, or be told
plainly that its runtime has none.

### Cause 3 — a failed fetch looks exactly like no options

`AppModel.loadDraftOptions` (`App/Sources/AppModel.swift:363`) sets `draftOptions = []` up
front, and on `catch` sets `problem` and leaves it empty. `isLoadingDraftOptions` is cleared by
`defer`. The result is the silent-gap state, and `prepare()` will not retry: it only runs from
`onAppear`, from a change in the runtime id list, and from a change in `agents.count`, and it
is additionally guarded by `model.draftOptions.isEmpty` — which is true, so it *would* retry,
but only if one of those three things happens to fire again. Nothing in the chat offers a retry.

**Decision**: Failure is a state the row shows and can be acted on, not a global `problem`
banner plus an empty row.

### Cause 4 — overlapping fetches, last writer wins

`loadDraftOptions` has no request identity. Changing the folder and then the runtime quickly
issues two calls; the first to return writes its `draftOptions` and its `defer` clears
`isLoadingDraftOptions`, so a stale row can be shown as settled while the right one is still in
flight. `chooseRuntime` and `chooseFolder` both call it directly, so this is two clicks apart.

**Decision**: A generation token, checked before every assignment. This is the standard fix and
costs one `Int`.

### Cause 5 — reviving an agent can blank its saved options

`ACPSession.setOption` already guards against this exact thing (`ACPSession.swift:330`):

```swift
let refreshed = ConfigOption.list(in: result["configOptions"])
if !refreshed.isEmpty { options = refreshed }
```

Three other sites assign the same value **unguarded**, into the record that gets saved:

| Site | Line |
|---|---|
| `start` | `DaemonCore+Commands.swift:61` |
| revive | `DaemonCore+Commands.swift:283` |
| `pickUp` | `DaemonCore+Runtimes.swift:132` |

Options reach a session by two routes: the `session/new` result (`ACPSession.swift:157`) and a
later `session/update` notification carrying `configOptions` (`SessionUpdate.swift:49` →
`ACPSession.swift:419`). A runtime that uses the second route has `session.options == []` at the
moment those three sites read it, so an agent that had a full row before a restart comes back
with an empty one, persisted. The already-correct `if !refreshed.isEmpty` guard is the precedent.

**Decision**: Apply the same guard at all three sites.

**Alternatives considered**: Waiting on options at start the way `options()` already waits 500ms
for commands (`DaemonCore+Commands.swift:22`). Rejected — it delays every start for a case the
notification handler at `DaemonCore.swift:200` already repairs the moment the update lands. The
guard is free; the wait is not.

### Cause 6 — the row is too wide for the pane it sits in, measured

The prompt bar and the transcript both carry `.padding(.horizontal, 144)` — 288 points of
gutter. The options row is an `HStack` of `.fixedSize()` capsules with `Spacer(minLength: 16)`
between the permission group and the rest. Nothing wraps and nothing scrolls, so anything that
does not fit is clipped.

Measured with CoreText at `NSFont.preferredFont(forTextStyle: .footnote)`, which resolves to
10pt — capsule width is text + 4pt gap + 8pt chevron + 20pt padding, 10pt between capsules:

| Row | Row width | Conversation pane needed |
|---|---|---|
| Claude, new chat (mode · model · thought level · Reach) | 405pt | 693pt |
| Claude, existing chat (no Reach) | 333pt | 621pt |
| Copilot, new chat | 350pt | 638pt |
| Grok, new chat | 304pt | 592pt |

Against that, `SidebarFrame` (`App/Sources/Sidebar/SidebarState.swift`) allows the sidebar up to
900pt and guarantees the conversation only `minimumConversationWidth = 520`. At the default
1100×720 window:

- sidebar closed: 812pt of content — fine
- sidebar at its default 380pt: **432pt of content, 27pt of headroom**
- sidebar past **407pt**: Claude's new-chat row no longer fits
- narrowest allowed conversation, 520pt: 232pt of content, the row **overflows by 173pt**

So dragging the sidebar a little wider than its default silently eats the controls from the
right — which is where `otherOptions` puts the model and the thought level. This is almost
certainly the "sometimes" the bug report is describing, alongside Cause 1.

**Decision**: Put the row in a horizontal `ScrollView` with `.scrollBounceBehavior(.basedOnSize)`.

**Rationale**: The comment already in `options` is a warning written in blood:

> Anything that measures the width and picks a layout from it can end up re-measuring what it
> just changed, and AppKit kills the app when that loop reaches the window: first a custom
> `Layout` did it, then `ViewThatFits` did it intermittently.

A scroll view reads its content's ideal width and never feeds a decision back into it, so there
is no loop to re-enter. `MentionList` and `AttachmentStrip` already use scroll views inside the
prompt bar, so this is the house pattern rather than a new idea.

**Alternatives considered**: `ViewThatFits` and a custom `Layout` — both already crashed this
app, per that comment. Shrinking the 144pt gutter at narrow widths — that is measure-and-decide
again, and the gutter is what lines the prompt up with the transcript. A `Menu` that collapses
the overflow — more chrome, and it still needs a width measurement to know when to collapse.

**Cost**: the `Spacer` that pushes model and effort to the right edge has to go, because a
spacer inside a horizontal scroll view has no width to take. Permission controls first, then a
fixed 16pt gap, then the rest. The left-to-right grouping the comment cares about survives; the
right-alignment does not. This is the one deliberate visual regression in the feature.

## 2. Clicking a project does not take you to the project

The intent is already written down and already correct. `AppModel.selectedProject`
(`App/Sources/AppModel.swift:51`):

```swift
var selectedProject: URL? {
    didSet {
        guard selectedProject != oldValue else { return }
        UserDefaults.standard.set(selectedProject?.path, forKey: Self.selectedProjectKey)
        // Picking a project shows the project, not a conversation. A chat is
        // something you go into from here, and come back out of.
        selection = nil
    }
}
```

`selection = nil` pops the `NavigationStack` in `ContentView`, whose path is
`openAgent` — a binding over `model.selection` holding nothing or one agent. So the mechanism
works. It is just unreachable for the one click that matters.

### Why the click never arrives

`ProjectListView` is a `List(selection: $model.selectedProject)` whose rows are plain
`ProjectRow` content carrying `.tag(summary.folder)`. On macOS a `List` selection binding is
driven by `NSTableView`'s selection-*changed* notification: clicking a row that is already
selected changes nothing, so the binding's setter is never called and `didSet` never runs.

And when you are on an agent page, the highlighted project **is** that agent's project. The
click you would naturally make to go back up — on the project you are already in — is precisely
the one the framework discards.

The `guard selectedProject != oldValue else { return }` would return early too, so even a
binding that did fire on a re-pick would not clear the selection. Two independent reasons,
which is why this needs a fix rather than a one-character change.

**Why it survived**: clicking a *different* project works perfectly. The binding changes,
`didSet` runs, the stack pops. The broken path is the one nobody writes a test for because it
looks like a no-op.

**Decision**: Make "go to this project" an explicit intent rather than a side effect of a
selection change.

1. `AppModel.showProject(_ folder: URL)` sets `selectedProject` and clears `selection`
   **unconditionally**. One place that knows the rule.
2. `ProjectRow` gets `.simultaneousGesture(TapGesture().onEnded { model.showProject(folder) })`.
   `simultaneousGesture` is the one gesture form that coexists with `List` selection rather
   than replacing it, so highlighting, keyboard navigation and the context menu all keep
   working. It fires on every click, including on the already-selected row.
3. `selectedProject.didSet` keeps its guard and keeps clearing `selection`. It is still right
   for a programmatic change — `settleProjectSelection`, `addProject` — and calling it twice is
   idempotent because of that same guard.

**To verify by running**: `simultaneousGesture` on a sidebar `List` row is the documented
workaround for this, but SwiftUI's sidebar rows have swallowed gestures before. If it turns out
to fight the selection highlight, the fallback is to make the row a `Button` with
`.buttonStyle(.plain)` and keep `List(selection:)` for the highlight only — more code, and it
tends to fight the sidebar's own styling, which is why it is second choice rather than first.
`quickstart.md` says exactly what to click.

**No conflict with the existing gestures**: `SwipeToArchive` is applied at
`ProjectAgentsView.swift:93`, on the agent cards, not on project rows. Project rows carry no
gesture today.

**Alternatives considered**

- *Intercepting the `List` selection binding's setter.* Does not help: the setter is not called
  when the value does not change, which is the entire bug.
- *Dropping the `guard` in `didSet`.* Does not help either, for the same reason, and it would
  write to `UserDefaults` on every no-op.
- *Removing the back button in favour of the sidebar.* The back control is the documented way
  home — `ContentView`'s own comment says so. This adds a second route; it does not replace the
  first.

**What must not change (FR-025)**: navigating away does not touch the agent. `selection` only
decides which transcript this window is watching — `work.watching = selection` and a transcript
load. The turn belongs to the daemon and carries on.

## 3. Getting back to the end of the conversation

`Transcript` already knows everything needed and shows none of it.
`onScrollGeometryChange` (`Transcript.swift:46`) computes an `Edges` value every frame with
`fromTop`, `fromBottom` and `canScroll`, and sets `isAtEnd = edges.fromBottom < 160`. That state
is used only to *suppress* auto-scrolling. There is no control anywhere in the app that scrolls
the transcript to its end, and `canScroll` is the exact predicate needed to keep such a control
hidden on a short transcript.

**Decision**: Three small additions, no new machinery.

1. A `hasNewBelow` flag on `Transcript`, set in the existing `onChange(of: model.entries.count)`
   when the guard already there (`isAtEnd`) fails, cleared when `isAtEnd` becomes true.
2. A button in an `.overlay(alignment: .bottom)` on the transcript, shown when
   `edges.canScroll && !isAtEnd`, offset by `bottomInset` so it clears the floating prompt —
   `ChatView` already measures that with `onGeometryChange` and passes it in.
3. Sending scrolls to the end. `PromptBar.send` is in a different view from the
   `ScrollViewProxy`, so this goes through the model: a token on `AppModel` that `send()` bumps
   and `Transcript` watches. `model.focusedEntry` / `clearFocus` (`Transcript.swift:75`) is the
   existing precedent for exactly this shape of cross-view scroll request.

**Rationale for a token rather than reusing `focusedEntry`**: the end of the transcript is not an
entry. The `bottom` anchor is a 1pt `Color.clear` with a constant id, and `focusedEntry` is a
`UUID?` that the artifacts pane owns for a different purpose.

**Keyboard route (FR-013)**: `AgentsApp` has no `.commands` block today. A menu command is the
honest place for it — it works whether or not the button is on screen, it is discoverable, and
it shows up in Help search. A `.keyboardShortcut` on the button alone would only fire while the
button exists, which is precisely when you least need the shortcut.

**Alternatives considered**: `defaultScrollAnchor(.bottom)` — that changes where the view rests,
not how you get back to it, and `settle()` already does the opening scroll deliberately. Making
the transcript always follow — that is the behaviour FR-010 exists to protect.

## 4. Remembering the mode

**Where the mode lives**: `ConfigOption.categoryOrder` puts `"mode"` first, and
`isAboutPermission` already treats `category == "mode"` as the permission control. The *id* is
conventionally `"mode"` — `SessionUpdate`'s `modeChanged` hard-codes it at `ACPSession.swift:424`
— but the category is what the app's own code keys on everywhere else.

**Decision**: Identify the mode option by `category == "mode"`, falling back to `id == "mode"`.
Remember one value per runtime id.

**Rationale**: Modes are runtime-specific. Claude's `acceptEdits` means nothing to Copilot, and
the spec's Assumptions record per-runtime as the chosen scope.

**Does seeding the draft actually take effect?** Yes, and this was checked rather than assumed.
`startDraft` sends `StartOptions(values: draftChosen)`, and `DaemonCore.start` calls
`await session.apply(request.startOptions)` (`DaemonCore+Commands.swift:77`), which loops
`setOption` over every value and swallows a refusal per option. So writing the remembered mode
into `draftChosen` is sufficient — no new daemon method, no protocol change.

**Where the preference is stored**: `UserDefaults`, alongside `sidebar.*` and
`selectedProject`. `SidebarFrame` is the pattern: `didSet` writes, `init` reads and sanitises.
The daemon must not hold this — its own comment draws the line, "the daemon owns things that
outlive windows", and a person's habitual mode is a preference about this Mac, not a fact about
an agent.

**Where the logic goes**: the resolve step — *is the remembered value still one this runtime
offers?* — is pure, is the only part that can be wrong, and belongs in `AgentsKitCore` where
`swift test` reaches it. The `UserDefaults` read and write stay in the app. This is the same
split `PageMetrics` uses: arithmetic in the package, pixels in the view.

**Staleness (FR-017)**: a remembered value that is no longer among the option's choices is
dropped and the runtime's `currentValue` is used. `ConfigOption.choiceName(for:)` already does
the membership test this needs, by the same route.

**What writes it**: both ends of `PromptBar.binding(for:)`. The draft branch writes
`draftChosen`; the agent branch calls `model.setOption`. FR-019 says changing the mode on a live
conversation also updates what is remembered, so the write goes in the binding's setter, above
that split, where it happens once.

## 5. Why an option control lags behind the click

`PromptBar.binding(for:)` is where it happens. The getter and the setter disagree about where
the truth is for an agent that exists:

```swift
get: {
    if let agent { return agent.startOptions.values[option.id] ?? option.currentValue }
    return model.draftChosen[option.id] ?? option.currentValue
},
set: { value in
    if let agent {
        Task { await model.setOption(agentID: agent.id, optionID: option.id, value: value) }
    } else {
        model.draftChosen[option.id] = value
    }
}
```

The draft branch writes somewhere the getter reads, so a new chat is already instant. The agent
branch writes nowhere the getter reads. It starts a `Task` and returns, and `SelectChoice`
immediately calls `dismiss()` — so the menu closes over a control still showing the old value,
and it stays that way for the whole round trip:

1. JSON-RPC to the daemon
2. `DaemonCore.setOption` → `ACPSession.setOption` → `session/set_config_option` to the runtime,
   which is a separate process that has to answer
3. `changed(agent)` → broadcast
4. the client's `AgentsModel` applies it and the getter finally sees it

Step 2 is unbounded. On a runtime in the middle of a turn it is long enough to be sure the
click did not land, which is why the reported symptom is "no response" rather than "slow".

**Decision**: an optimistic value, held only while the change is in flight.

`AppModel` gains `pendingOptions: [UUID: [String: JSONValue]]`. The setter writes it
synchronously — before the `Task` — so the getter sees the new value on the same frame the menu
closes. The getter reads `pending → agent.startOptions → option.currentValue`. When the call
returns, the pending entry is removed and the record takes over (FR-032, FR-033, FR-034).

### Why clearing on the response is safe

The worry is a flicker: clear the optimistic value a moment before the real one lands and the
control snaps back and forward. It does not happen, because of the order the daemon already
writes in. `DaemonCore.setOption` calls `changed(agent)` **before** it returns, and
`changed` calls `broadcast` synchronously (`DaemonCore.swift:123`). Notification and response
go out over the same `LineTransport` stream, in that order, and the client reads that stream in
order. So by the time `setOption` returns, the record already carries the new value.

**To confirm by running** — this is an ordering argument, not a guarantee. If a flicker does
appear, the fallback is to keep the pending value until the record's value for that option
changes, with the call's completion as a deadline rather than the trigger.

### Refusals, and two clicks in a row

- A runtime that refuses, or that answers with a different value, is handled by the same
  mechanism: the pending value goes when the call completes, and the record's value — the one
  actually in force — is what the control settles on (FR-034). `ACPSession.setOption` already
  returns the refreshed list, and `DaemonCore` already writes it to `advertisedOptions`.
- Where the call itself fails, `AppModel.attempt` already shows the problem. FR-035 asks that
  the control not revert silently, and that is what `attempt` is for; the pending value goes
  and the control shows what is still in force, with the reason on screen.
- Two clicks in a row (FR-036) is the one that needs care. Keying pending by
  `[agentID][optionID]` means the second write overwrites the first, which is right — but the
  first call completing must not clear the second's value. So the pending entry carries a
  sequence number, and a completing call only clears the entry if it is still the one it wrote.
  This is the same generation-token shape as cause 4 in §1, for the same reason.

**Alternatives considered**

- *Writing to `agent.startOptions` locally.* That is the daemon's record, mirrored in
  `AgentsModel`; a client that edits it is a client that can disagree with the daemon with no
  way to notice. The pending map is explicitly temporary and cannot be mistaken for truth.
- *Disabling the control while in flight.* Honest, and worse: the control is unusable for
  exactly as long as it is currently wrong, and it still does not show the choice.
- *A spinner on the capsule.* It answers "did it land" but not "what did I pick", and it puts
  motion in a row that is meant to be read at a glance. Worth revisiting only if the wait turns
  out to be long enough that people change the option twice anyway.

## 6. An agent that shows a file, to nobody

`DaemonCore.showFile` (`DaemonCore+AppTools.swift:89`) checks the token, the folder scope and
the file, then broadcasts and returns. Its own comment is explicit about what it does not do:

> Nothing is stored: a file worth looking at now is not worth reopening a week from now, so
> this goes out as an event and is gone.

The client keeps it: `AgentsModel.filesToShow[agentID] = notification.file`
(`AgentsModel.swift:90`), removed by `takeFileToShow`. And `ContentView.showWhatWasAskedFor()`
reads it **only for the selected agent**, by an equally deliberate decision:

> An agent working in another conversation keeps its request until that conversation is opened,
> rather than pulling the window away from what is being read: the file is the agent's
> suggestion, and the window is still the user's.

Both decisions are right. The gap is between them: the request is kept, correctly, and nothing
anywhere says it is being kept. The agent has meanwhile been told "`X` is open in the files pane
beside this conversation. Say what they are looking at" — so it writes a reply about a pane the
person is not looking at, and the app has made the agent appear wrong.

### Why this must not be `waitingOnUser`

The obvious move — put the agent in the state that already means "needs attention" — would be a
bug, not a shortcut. `AgentGroup.needsAttention` is derived from `AgentState.waitingOnUser`
alone, and that state carries two other meanings:

- `holdsRuntime == true` — the daemon believes it is holding a live runtime for it
- `hasTurnInFlight == true` — so `PromptBar.willQueue` would start queueing prompts

Showing a file blocks nothing; the agent carries on working. And `AgentState.applying` has no
way back out of `waitingOnUser` except `permissionAnswered`, so an agent that showed a file
would be stuck there. **Decision**: the mark is not a state. The state machine is untouched.

### Why it does not need a daemon record either

The first design was a field on the `Agent` record so the daemon's `ProjectSummary.counts`
would light the sidebar dot. That reverses the "nothing is stored" decision above, adds a wire
method for "the person has now seen it" — which the daemon cannot know on its own, since it has
no idea which conversation a window is showing — and makes a persisted flag out of something
that should not outlive the window.

None of it is necessary. The client already holds everything:

- `AgentsModel.filesToShow` is keyed by agent id and already survives until that conversation
  is opened. That *is* the "unseen" flag, already correct, already clearing at the right moment.
- The project page groups agents client-side — `ProjectAgentsView` calls
  `model.agents(in: folder, group: group)` over `AgentGroup.live`, and `Agent.group` is computed
  in the client. So the agent can be grouped under "Needs attention" with no daemon involvement.
- The sidebar dot is the only thing that reads a daemon count — `ProjectRow` draws it from
  `summary.needsInput`, which is `counts[.needsAttention] > 0`. But `ProjectRow` can take
  `AppModel` from the environment, as `ArchivedProjectRow` beside it already does, and or in
  whether any agent in that folder has an unseen file.

**Decision**: client-side throughout. No record field, no daemon method, no protocol change, and
the "nothing is stored" decision stands.

### The shape of it

1. `AgentGroup` gains a second input rather than a second source of truth:
   `init(for state: AgentState, wantsEyes: Bool)`, with the existing `init(for:)` kept as
   `wantsEyes: false`. Still total over its inputs, so `AgentGroupTests`' exhaustion still
   means something, and an agent still cannot be in two groups or none.
2. `AppModel.agents(in:group:)` passes `filesToShow[agent.id] != nil`.
3. `ProjectRow` shows its dot when `summary.needsInput` **or** any agent in that folder has an
   unseen file.
4. Nothing else. `showFile`, the notification, `takeFileToShow` and
   `ContentView.showWhatWasAskedFor` are all unchanged — opening the conversation already
   consumes the entry, which clears the mark for free (FR-028).

**What to watch**: `AgentRow.description` and `StatusIcon` read `agent.state`, not its group, so
a marked agent still reads "Working" with the working spinner — which is exactly what FR-029
asks for. The group heading is the only thing that moves. Worth checking by eye that a card
under "Needs attention" showing a spinner does not read as a contradiction; if it does, the
card needs a line saying *why* it is there, not a change of state.

## 7. Two clicks to answer a one-word question

`ElicitationView.field(for:)` draws a string property that carries `enum` choices as a
`Picker` with `.pickerStyle(.radioGroup)`, and the form's Send button sits below every field.
So the smallest possible question — one property, one list of choices — costs a click on the
radio and a click on Send.

`PermissionView`, twelve lines away, already does the one-click version of the same thing:

```swift
ForEach(request.options) { option in
    Button(option.name) { answer(option) }
        .buttonStyle(option.kind.allows ? .glassProminent : .glass)
}
```

The agent's own wording, on buttons, answered outright. A single-choice elicitation *is* a
permission question wearing a form, and the app currently answers the two differently.

**Decision**: when a form's whole answer is one choice, draw it the way `PermissionView` draws
one and send on the click. Otherwise leave it exactly as it is.

### The condition

The shortcut applies when **all** of these hold, and the check belongs in `AgentsKitCore` where
`swift test` can reach it rather than in the view:

- `request.mode` is `.form`
- the schema has exactly one property
- that property's kind is `.string` with a non-nil `choices`

Anything else — a second field, free text, a number, a multi-select — keeps the radio group and
the Send button, because a partial answer cannot be sent (FR-041). The existing
`schema.problems(with:)` validation is unchanged and still gates the Send path.

### What the buttons are

- One button per choice, carrying `choice.title`, in the order the agent sent them.
- `choice.description` stays visible. The comment already in the view is the reason —
  "what separates two options is usually their description, and a menu has nowhere to put it" —
  so this must not become a bare row of words (FR-043). A button with a title and a caption
  under it, as `SelectChoice` already draws.
- Where the property is not required, the existing "No answer" row becomes a button too
  (FR-040), sending `.accept` with an empty value exactly as picking that row does today.
- "No thanks" stays as it is, sending `.decline` (FR-042). Declining the question and giving no
  answer to it are different things and the daemon already distinguishes them.

### Width

A row of buttons has the same problem §1.6 measured for the options row, in the same 144pt
gutter, and a choice's wording is the agent's rather than ours so there is no bound on it. The
same answer applies: a horizontal scroll view, or wrapping to a second line if the choices are
few and short. No measure-and-decide layout, for the reason recorded in §1.6.

**Alternatives considered**

- *Send on selection, keeping the radio group.* One click, and invisible: a radio that commits
  the moment it is touched is a control that has lied about what it is. Buttons say
  "this does something" the way radios say "this records a preference".
- *Applying it to a single boolean too.* Two buttons instead of a toggle plus Send, by exactly
  the same argument. Left out because the request named the choice list; noted in the spec's
  Assumptions as the obvious next one.
- *Applying it to multi-select.* Cannot be one click by definition.

## 8. What is not being changed

- The transcript's opening scroll, its follow-while-at-the-end behaviour, and the anchor it
  keeps when earlier history loads (`Transcript.swift:88`, `:112`). FR-010 and FR-014 are
  descriptions of code that is already right, and they are there so a fix for FR-007 does not
  break them.
- The protocol. No new daemon method, no new ACP call, no new notification.
- Any other option. FR-020 limits the memory to the mode.
- The back control in the toolbar, and `NavigationStack` as the shape of getting into and out
  of a conversation. Story 2 adds a route; it removes none.
- `AgentState` and its transition table. Story 5 adds a mark, not a state, for the reasons in
  §5. `showFile` itself is not touched at all.
- The rule that a file is shown immediately when its own conversation is on screen. Story 6 is
  only about the case where it is not.
- The elicitation protocol, `schema.problems(with:)`, and the distinction between declining a
  question and answering it with nothing. Story 7 changes how one shape of form is drawn and
  nothing about what is sent.
- `DaemonCore.setOption` and the ACP call under it. Story 3 is entirely in the app: the daemon
  is already as quick as the runtime lets it be.

## 9. Working tree

The branch is `main` and the tree is mid-way through the `AgentsKit` → `AgentsKitCore` split
that feature 005 started; `git status` shows renames staged across `ACP/`, `Client/` and
`Daemon/`. Nothing in this feature adds a file to a target that is moving, and the two new types
below go into `AgentsKitCore`, which is where the split is putting model code anyway.

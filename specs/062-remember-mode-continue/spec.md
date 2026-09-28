# Feature Specification: Remember Mode on Continue

**Feature Branch**: `agents/remember-mode-rule`

**Created**: 2026-09-27

**Status**: Draft

**Input**: User description: “Add a Remember mode rule to Continue. Keep it compact beside Matching models; remember the mode picked when continuing between runtimes, without adding a mode-matching grid.”

## User Scenarios & Testing

### User Story 1 - Remember a mode when continuing (Priority: P1)

A person continues a chat from one runtime to another, chooses a destination mode, and turns on **Remember this for next time**. On a later move along the same runtime pair, the app can reuse that choice when it is still available and no looser than the mode the chat is leaving.

**Why this priority**: The setting exists to keep a person's mode correction from being lost the next time they move between runtimes.

**Independent Test**: Continue a chat from Runtime A to Runtime B with a mode choice and Remember on. Continue another eligible chat from A to B and verify the saved choice is selected and identified as the last choice for that route.

**Acceptance Scenarios**:

1. **Given** both runtimes offer a mode and the destination offers the chosen mode, **When** the person confirms Continue with Remember on, **Then** the app remembers the destination mode for the directed A-to-B route.
2. **Given** a remembered mode is available and no looser than the current chat's mode, **When** the app previews another Continue or carries the chat automatically from A to B, **Then** it selects the remembered mode and identifies it as the last mode chosen when continuing to B.
3. **Given** Remember is off, **When** the person confirms Continue, **Then** this Continue does not change either the remembered mode for A-to-B or the existing Matching models behavior.

---

### User Story 2 - Keep the choice compact and predictable (Priority: P1)

The person sees one **Remember this for next time** toggle beside the existing model-pair controls. They do not need to maintain a second settings grid. The choice applies to this directed route only; moving in the opposite direction has its own remembered choice.

**Why this priority**: A small, understandable rule fits how people use Continue and avoids a second grid that duplicates the model-matching interface.

**Independent Test**: Save a mode from A to B, then inspect B to A and verify it does not inherit the A-to-B choice. Confirm that the Pool page has no mode grid or mode cells.

**Acceptance Scenarios**:

1. **Given** the person has selected a destination mode in Continue, **When** they turn on Remember, **Then** the existing toggle explains that it saves the model pair in Matching models and the mode for this runtime route; no second mode toggle is shown.
2. **Given** a mode was remembered from A to B, **When** the person continues from B to A, **Then** the A-to-B choice is not used for that reverse route.
3. **Given** a Continue is opened to adjust settings after an automatic switch, **When** the person changes the mode, **Then** the change applies to this chat from its next turn and does not write a Continue mode memory.

---

### User Story 3 - Preserve mode safety when choices change (Priority: P2)

A remembered choice must not make a chat less strict than it was before a move. If a runtime no longer offers the remembered choice, the app falls back to its existing mode selection behavior and lets the person choose another offered mode in Continue.

**Why this priority**: A saved preference must remain safe as runtime capabilities and the chat's own mode change.

**Independent Test**: Save a mode, then preview a move with a stricter source mode and with a destination that no longer offers the saved choice. Verify that the saved choice is ignored and the existing safe fallback remains available.

**Acceptance Scenarios**:

1. **Given** the remembered mode would be looser than the chat's current mode, **When** the app plans the move, **Then** it ignores the remembered mode, keeps the remembered value stored, and uses the existing no-looser fallback.
2. **Given** the destination no longer offers the remembered mode, **When** the app plans the move, **Then** it ignores that value and uses the existing fallback; the memory remains available if the runtime offers the value again later.
3. **Given** either runtime has no selectable mode, **When** the person turns on Remember and confirms Continue, **Then** the app saves no mode choice and continues to handle any model-pair memory as it does today.
4. **Given** a saved mode remains available and later becomes no looser than the chat's current mode, **When** the next eligible move is planned, **Then** the saved choice can be used again.

---

### Edge Cases

- The same mode is offered on both runtimes: retain the current mode before considering the remembered route choice.
- A remembered value is no longer offered by the destination: ignore it without deleting it, and use the existing fallback.
- A remembered value is stricter than the chat's current mode: it is eligible; a looser value is not.
- A runtime's mode names cannot be ordered by the app: only an exact same value is considered equally strict; other unknown values are not used as a remembered match.
- The chat has no current mode, or either side has no selectable mode: do not save or apply a mode memory.
- The destination's offered modes are not yet known: continue with the existing unknown-options behavior; do not invent or save a mode value.
- The person changes the destination mode in the Continue sheet: the person's selection wins for that move and is the value saved when Remember is on.
- Remember is on but there is no model value to place in Matching models: mode memory can still be saved when both sides offer a mode and the destination has a selected mode.
- A mode-memory write fails after the chat has continued: the move still succeeds; the failure does not undo the move or the model-pair memory.
- Continue is cancelled or refused: do not change mode memory.

## Requirements

### Functional Requirements

- **FR-001**: The existing **Remember this for next time** control MUST remember the selected destination mode for the directed source-runtime-to-destination-runtime route when the person confirms Continue.
- **FR-002**: The same control MUST continue to remember the selected model pair using Matching models as it does today; it MUST NOT add a mode column, mode grid, or separate mode toggle.
- **FR-003**: A saved mode MUST be considered for both manual Continue previews and automatic runtime switches between the same directed runtime pair.
- **FR-004**: The app MUST prefer the chat's current mode when the destination still offers that exact value. Otherwise, it MUST consider the remembered route mode before the existing closest-no-looser or strictest-mode fallback.
- **FR-005**: The app MUST use a remembered route mode only when the destination still offers that value and the value is no looser than the mode the chat is leaving.
- **FR-006**: A remembered mode MUST NOT be used to loosen a chat's mode. The existing confirmation-time validation MUST continue to reject any person-selected mode that is looser than the chat's mode.
- **FR-007**: The person-selected destination mode MUST take precedence over the previewed value for the current Continue and MUST be the value remembered when Remember is on.
- **FR-008**: Each ordered runtime pair MUST have its own remembered mode; A-to-B and B-to-A are independent. A later Remember on the same route replaces that route's previous mode.
- **FR-009**: A value that is no longer offered or is currently too loose MUST be ignored without deleting the saved route choice.
- **FR-010**: Mode memory MUST only be saved after a confirmed, successful Continue, when both runtimes offer a selectable mode and the destination has a mode value. A mode-memory write failure MUST NOT undo the Continue or its existing model memory.
- **FR-011**: Turning Remember off, cancelling/refusing a Continue, or using the post-switch adjustment sheet MUST NOT change route mode memory.
- **FR-012**: When no eligible mode value exists or destination options are unknown, the app MUST omit mode-memory behavior and retain existing Continue behavior.
- **FR-013**: The Continue sheet MUST identify a mode selected from route memory as “the last time you continued to [runtime]”, distinguishing it from a runtime's last-used mode for new sessions.
- **FR-014**: The Remember supporting text MUST state when it saves a route mode, alongside the existing model-pair memory. If either side has no selectable mode, it MUST describe only the model-pair memory.
- **FR-015**: Documentation MUST explain how Continue remembers mode and that the existing no-looser rule still applies.

### Key Entities

- **Continue mode memory**: The latest mode chosen for one ordered pair of runtimes, independent of the mode remembered for starting a new chat on a runtime.
- **Mode choice**: A selectable mode value offered by a runtime. The choice is usable only while the destination offers it and the no-looser rule allows it.
- **Matching models level**: The existing named model pairing memory. It remains about models and effort, with no mode cells.

## Success Criteria

### Measurable Outcomes

- **SC-001**: In a confirmed A-to-B Continue with Remember on, the next eligible A-to-B manual Continue preview and automatic switch both select the remembered destination mode.
- **SC-002**: A-to-B and B-to-A memories remain independent, and remembering a newer A-to-B choice replaces the earlier A-to-B choice.
- **SC-003**: In every case where the saved value is unavailable or looser than the current chat mode, the app uses the existing fallback and never selects the looser saved value.
- **SC-004**: Continue with Remember off, cancelled, refused, or used only to adjust an already switched chat creates no route mode memory.
- **SC-005**: The Pool page continues to show Matching models without a mode grid, mode column, or mode cells.

## Docs

- `docs/how-to/keep-going-when-a-runtime-runs-out.md` — explain that Remember also saves the mode for the next move along the same runtime route, subject to the no-looser rule.
- `docs/reference/settings.md` — no change; no new setting or Pool control is added.

## Assumptions

- Remember remains opt-in through the existing Continue toggle.
- There is one remembered mode per directed runtime pair, not a separate value for each source mode. The app rechecks safety when the value is used.
- Manual Continue and automatic switches use the same route-memory rule.
- A remembered route mode is available wherever that Mac's pool is available, including connected server projects.
- Runtime-start mode memory remains separate and continues to supply defaults for new chats and prompt-bar changes.
- The post-switch adjustment sheet does not save a route mode because it adjusts only the current chat.

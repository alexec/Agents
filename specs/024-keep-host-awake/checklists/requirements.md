# Specification Quality Checklist: The Mac Stays Awake While Its Agents Work

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-09-23
**Feature**: [spec.md](../spec.md)

## Content Quality

- [X] No implementation details (languages, frameworks, APIs)
- [X] Focused on user value and business needs
- [X] Written for non-technical stakeholders
- [X] All mandatory sections completed

## Requirement Completeness

- [X] No [NEEDS CLARIFICATION] markers remain
- [X] Requirements are testable and unambiguous
- [X] Success criteria are measurable
- [X] Success criteria are technology-agnostic (no implementation details)
- [X] All acceptance scenarios are defined
- [X] Edge cases are identified
- [X] Scope is clearly bounded
- [X] Dependencies and assumptions identified

## Feature Readiness

- [X] All functional requirements have clear acceptance criteria
- [X] User scenarios cover primary flows
- [X] Feature meets measurable outcomes defined in Success Criteria
- [X] No implementation details leak into specification

## Notes

Two revisions were made during validation, both against "no implementation details":

1. FR-002 and FR-003 originally named the state values and `AgentState.hasTurnInFlight`
   directly. Rewritten as *starting* and *working* in prose, matching how 020's spec talks
   about the same states. The pointer to "the app's existing notion of a busy
   conversation, less the one case below" keeps the requirement anchored without naming a
   symbol.
2. SC-006 originally proposed verification "by inspecting the system's assertion list".
   Restated as the observable outcome — the Mac sleeps on its normal timer with nothing to
   clear up.

Three scope questions were settled by the reader before drafting rather than being left as
[NEEDS CLARIFICATION] markers, and each is recorded in Assumptions:

- What counts as running: turns in flight only (starting and working), **not** an agent
  waiting on the person. The cost of this — an answer from the phone may arrive at a
  sleeping Mac — is stated in the assumption rather than hidden.
- How far wakefulness goes: system sleep only. The display, the lock screen and explicit
  sleep are untouched.
- Battery: held always on mains; on battery, held only above a reserve floor. The floor is
  assumed to be 20% and is not a user setting in this version.

Three things are deliberately out of scope and said so in the spec: waking a sleeping Mac,
surviving the lid closing, and any setting to turn the feature off.

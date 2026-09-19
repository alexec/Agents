# Specification Quality Checklist: Cursor makes four

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-09-18
**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] No implementation details (languages, frameworks, APIs)
- [x] Focused on user value and business needs
- [x] Written for non-technical stakeholders
- [x] All mandatory sections completed

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable
- [x] Success criteria are technology-agnostic (no implementation details)
- [x] All acceptance scenarios are defined
- [x] Edge cases are identified
- [x] Scope is clearly bounded
- [x] Dependencies and assumptions identified

## Feature Readiness

- [x] All functional requirements have clear acceptance criteria
- [x] User scenarios cover primary flows
- [x] Feature meets measurable outcomes defined in Success Criteria
- [x] No implementation details leak into specification

## Notes

- Items marked incomplete require spec updates before `/speckit-clarify` or `/speckit-plan`.
- Validation run 1 flagged two things and both were fixed in place: an assumption that named a
  protocol error code, softened to "a request it does not know", and Success Criteria that named the
  Cursor extension methods, rewritten as user-facing outcomes.
- Validation run 3 replaced guesses with a handshake, run on 2026-09-18 against `cursor-agent`
  2026.09.10-fd3934a. One claim was wrong and is now corrected: the spec said the app would show which
  model Cursor reports "as it does for the others". It does not. Cursor reports its models where the
  app has deliberately decided not to read, and offers none of the providers the app does read, so a
  Cursor agent shows no model at all. That is now stated, and picking a model is out of scope.
- The same run turned three assumptions into facts, which the spec records in "What Cursor actually
  says": it can load a session, it takes pictures but not embedded context, and it offers one way to
  sign in and no way to sign out. It also found a hazard worth a requirement of its own. Cursor's
  sign-in text says to run `agent login`, and `agent` on this Mac is Grok's binary, so FR-005a now
  forbids passing a runtime's own instructions on as advice.
- Scope is bounded by priority rather than by a clarification question. P1 puts Cursor on the list,
  P2 is the honest account state, P3 is Cursor's own extension requests. A plan may stop after P1 and
  still ship something worth having, as long as FR-008 holds.
- Out of Scope and Dependencies were added after the first pass, which had neither. Most of what this
  feature needs is owned by 003, and saying so is what stops it being rebuilt: capability-driven
  behaviour (US1), sign-in state (US5), the plan (US6), adopting a session (US7) and answering a
  structured question (US9). 004 owns the group that means an agent needs the user.
- Two open questions carried from elsewhere, both recorded under Dependencies rather than as markers
  here. 003 task T076, what a signed-out runtime actually returns, is unproved and User Story 2
  scenario 2 rests on it. And 003 User Story 9 builds a form for the protocol's way of asking, while
  Cursor asks by a name of its own, so planning has to decide whether the two meet.
- One thing planning must confirm on the machine rather than from documentation: the name of the
  installed binary and the exact subcommand that starts it in protocol mode. Cursor's documentation
  writes it as `agent acp`, while the installer is widely reported to place `cursor-agent`.

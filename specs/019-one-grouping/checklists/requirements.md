# Specification Quality Checklist: One Grouping, and Everything Agrees With It

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-09-19
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

Written from a code reading, not from a reproduction. Three defects were traced before
drafting and each is stated as a scenario rather than as a patch:

1. **Two functions compute the group and one cannot see whether an agent asked to be
   looked at.** The one the daemon uses to produce project counts is the blind one, so
   counts and lists disagree. Covered by User Story 1 and FR-006 through FR-010.
2. **The check for "does anything here want a person" ignores agent state**, while the
   grouping deliberately does not — so a stopped agent can make a project claim someone
   is wanted. Covered by User Story 2 and FR-011 through FR-013.
3. **The app's own question about a silent ending runs as an ordinary turn**, moving a
   finished agent into Working and back unbidden. Covered by User Story 3 and FR-014
   through FR-018.

One decision was taken by the user up front rather than left as a clarification:

- **An agent under the app's outcome question stays under Complete**, rather than moving
  to Working or getting a fifth heading. Recorded as FR-014 and in Assumptions, with the
  reasoning.

One open design question is stated as a requirement rather than an answer, deliberately.
FR-009 says a count produced where a fact is unavailable must be completed before anybody
sees it, without saying where that completion happens. The daemon cannot know what a
window knows, and choosing between "the client adjusts the count" and "the row recomputes
locally" is a planning decision, not a specification one.

A related ordering weakness was found and deliberately left out of scope: the function
that returns a group's agents promises "newest activity first" but applies no sort, and
is correct today only because the underlying collection happens to be sorted on ingest.
It is not a grouping defect and does not currently misbehave.

Items marked incomplete require spec updates before `/speckit-clarify` or `/speckit-plan`.

# Specification Quality Checklist: Remotes for iPhone and iPad

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
- Validation run 1 raised two wordings that read as network jargon rather than user outcomes
  ("carrier-grade NAT", "ciphertext"). Both were rewritten as plain conditions a tester can set up.
  All items passed on run 2.
- The spec depends on feature 004 (`specs/004-project-focused-ui`) for its information architecture:
  projects, the three agent groups, and the archived agent list. Planning 005 assumes 004 is built.
- Three decisions carry the most weight and are the first candidates for `/speckit-clarify`: allowing
  a rendezvous in the middle that cannot read the traffic; leaving a sleeping Mac unreachable rather
  than waking it; and keeping project creation and project archiving at the Mac.

## Post-plan note (2026-09-18)

Planning surfaced three places where the spec's wording outran what the platform can do. They are
recorded in `plan.md` under "Deviations from the spec" and need a decision before `/speckit-tasks`:

- **FR-007** says pairing is "an exchange begun at the Mac". It is begun on the phone and confirmed
  at the Mac. Proposed: amend to "confirmed at the Mac".
- **SC-006** says 1 second each way. A store-and-forward channel is seconds. Proposed: amend to
  "within 3 seconds while the remote is in front", and give the 1-second figure to FR-004.
- **FR-004** (prefer a direct connection) is a whole second transport and is planned as the last
  phase. If cut, it and the tighter half of SC-006 should come out of the spec.

The spec has not been edited — these are the user's calls, not the plan's.

One assumption in the spec also hardened into a constraint: the feature needs both devices signed
into the same Apple Account with iCloud Drive on. That is narrower than "no account" implied and is
called out in the plan's Constitution Check.

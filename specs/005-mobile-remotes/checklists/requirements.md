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
recorded in `plan.md` under "Deviations from the spec". **Two of the three are now settled and the
spec has been edited** (2026-09-19):

- **FR-007** says pairing is "an exchange begun at the Mac". It is begun on the phone and confirmed
  at the Mac. Proposed: amend to "confirmed at the Mac". **Still open — the user's call.**
- **SC-006** said 1 second each way. A store-and-forward channel is seconds. **Settled**: SC-006 now
  carries both figures, 1 second on the direct link and 3 seconds on the relayed one.
- **FR-004** (prefer a direct connection) was planned as an optional last phase. **Settled, in the
  opposite direction**: the direct link is built and both links are now required. FR-004a to
  FR-004c cover selection, telling the user, and the single security model across both. See
  `research.md` §11 for why the order reversed, and `contracts/transport.md` for the design.

One thing the reversal put on the register, which no requirement covered before: the direct link as
built has **no pairing and no encryption**. FR-004c exists to say that a home network earns no
discount, and tasks T024e to T024h are what close it. It must not ship in its current state.

One assumption in the spec also hardened into a constraint: the feature needs both devices signed
into the same Apple Account with iCloud Drive on. That is narrower than "no account" implied and is
called out in the plan's Constitution Check.

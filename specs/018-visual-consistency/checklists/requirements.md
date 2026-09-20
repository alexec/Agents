# Specification Quality Checklist: Visual Consistency — One Attention Colour, One Chat Scale, One Measure

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

Three decisions were taken by the user up front rather than left as clarifications:

- **Attention colour is orange; red stays for failure.** A waiting agent is not a broken
  one, and drawing both the same way would spend the app's one loud colour on two
  different meanings. Recorded as FR-002.
- **Chat gets bigger by raising the chrome to the prose, not by enlarging the prose.**
  This answers "it seems a bit small" without costing transcript density. Recorded as
  FR-010 through FR-012 and in Assumptions.
- **The chat's fixed margin becomes a centred ceiling on column width.** Raised by the
  user after the first draft: a narrow window is currently mostly padding. The column
  centres once the pane exceeds the measure, matching the phone and iPad rather than
  staying pinned left. Recorded as FR-017 through FR-023 and in Assumptions.

Named surfaces (Mac agent list, phone agent card, and so on) are user-visible places,
not implementation structure, and are kept because a requirement that cannot name where
it applies cannot be checked.

### Amended during `/speckit-plan` (2026-09-19)

Planning surfaced a contradiction the spec could not be built around, and two gaps:

- **FR-002 and FR-006** amended to allow **green** as a third colour, for a completion the
  agent vouched for itself. As first drafted, FR-006 would have deleted the green `done`
  tint that 014 introduced on purpose (its FR-012). Alex chose to keep it, so the rule is
  three colours with one meaning each rather than two.
- **FR-006a** added: orange was already spent on three things that do not need a person —
  a missing artifact, a cost-limit warning, and an agent at its limit. Leaving them would
  have satisfied FR-003 while failing SC-001. All three move to the failure colour.
- **FR-006b** added: a colour on an ordinary control, such as the button that opens a diff,
  is not a state tint and is out of scope. Without this the FR-024 check would flag it on
  its first run.

SC-001 was tightened to match. The checklist was re-validated after these amendments and
all items still pass.

Items marked incomplete require spec updates before `/speckit-clarify` or `/speckit-plan`.

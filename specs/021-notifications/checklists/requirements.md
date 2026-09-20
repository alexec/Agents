# Specification Quality Checklist: Notifications, Where The Person Actually Is

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

Four decisions were settled with the user before drafting rather than left as markers:
presence by most-recently-used surface; delivery that reaches the person anywhere, not
only on the home network; notifying for blocked agents and for turns that ended needing a
person, and for nothing else; and one live notification that follows the person rather
than escalating or broadcasting.

Three thresholds are named in the requirements but not numbered — how long the Mac may be
idle before it counts as away (FR-007), how stale a device's last use may be before it
stops counting as where the person is (FR-008), and the settling pause and re-alert
interval (FR-014, FR-018). They are deliberately left to `/speckit-plan`: each is a tuning
value that wants measuring against the real apps, and fixing them here would pin numbers
nobody has yet observed. Every one has a testable rule around it.

**Amended 2026-09-19, after `/speckit-plan`.** Three requirements were changed on the
strength of research findings, with the user's agreement, rather than left to be discovered
during implementation:

- **FR-007 and FR-005(b)** now say "at the Mac" requires a connected Mac surface. `agentsd` is
  not an app and cannot post a banner; a Mac with no window is not a place a notification can
  go, however awake the machine is. (research §5, §6)
- **FR-010** now says the need waits and the next surface to connect is told, rather than
  falling back to the Mac — which was unbuildable in precisely the case it was written for.
  US2 scenario 6 and the Mac-fallback assumption were corrected to match. (research §6)
- **SC-003** now promises 5 seconds for foregrounded surfaces and "by the time it is next
  opened" for a backgrounded device. Withdrawal there needs a silent push, and silent pushes
  are throttled by the operating system. (research §8)

Items marked incomplete require spec updates before `/speckit-clarify` or `/speckit-plan`.

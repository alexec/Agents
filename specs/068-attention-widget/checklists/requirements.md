# Specification Quality Checklist: Attention on the Home screen

**Purpose**: Validate completeness and clarity before planning
**Created**: 2026-09-29
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

- FR-001 and FR-019 hold one thing to one rule: the number on the widget is the number the
  Mac's Dock badge shows, and no new definition of "needs you" is introduced here. A widget
  that computed its own count would be a second source of truth, which is the failure this
  codebase has been written to avoid.
- FR-009 and FR-017 are the honesty requirements. With no information the widget must say
  so rather than show a zero, and with old information it must not present it as current:
  a widget that looks live and is not is worse than no widget.
- FR-014 keeps the widget a view. It holds no connection and answers nothing, which is also
  021's boundary on acting on a notification.
- FR-015 is what makes this safe to put on someone's Home screen: the file is on that
  device, holds ids and names rather than conversations, and goes when the app does.
- The one freshness the spec cannot promise is a need raised while the person is at the
  Mac, where no silent push is sent to the device. That is recorded in Assumptions and left
  to the Out of Scope item that names the mailbox as its own feature.
- Items marked complete reflect review of the specification, not completed implementation.

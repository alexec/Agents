# Specification Quality Checklist: Enterprise T5, policy

**Purpose**: check the spec is complete before the build.
**Created**: 2026-10-21
**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] Each requirement says what, not how, except where it names the existing code it extends
- [x] Written for the people who decide (Alex, the scrum master) and the lanes that build
- [x] All mandatory sections are filled

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] is left: each open question is decided in Clarifications
- [x] Each requirement can be tested, and the tasks say which test
- [x] Success criteria can be measured, and name no technology
- [x] Each user story has acceptance scenarios and an independent test
- [x] Edge cases are listed
- [x] Scope is bounded: "Not in this spec" in Assumptions
- [x] Assumptions and what it builds on (spec 736, #1804) are named

## Feature Readiness

- [x] Each functional requirement has at least one task (checked by hand, 2026-10-21)
- [x] User stories cover the issue's list: rules, "set by your organisation", offline, MDM and `/etc`, T6, T8 and #840, budgets
- [x] Slices map to feature areas (`plan.md` ▸ Slices for the build)

## Notes

- Decided items carry "Alex can overrule" in the Decisions table and on #998.

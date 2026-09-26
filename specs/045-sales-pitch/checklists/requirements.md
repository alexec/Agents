# Specification Quality Checklist: Why Agents — the pitch

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-09-25
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

- The Docs section names files (`mkdocs.yml`, the spec template) because the feature *is* docs; this
  is the template's own requirement, not an implementation leak.
- D1–D3 confirmed by Alex; D4 (the reader) is a default.
- Claims were checked against the docs on main (e.g. "keeps the Mac awake" is only while a turn is in
  flight; a Mac restart stops agents and they resume on next open).
- Revised 2026-09-25 at Alex's prompt: leases, events and workflows promoted to a headline pillar (US3, FR-004/004a, SC-007) and 042's missing docs pulled into scope (FR-016, SC-008). Every event name the example uses (pull_request.checks_failed/checks_passed, custom.*) is raised on main.
- Fixed 2026-09-25: stale 043/042 statements after main moved to 075d9f9; the order of the reasons at the top now matches FR-004; the notification wording now matches the docs; the example's custom event now has a reason; server.* events are listed but never raised (an app bug, excluded from the docs); README's stale 'lead' paragraph; server docs lag 043 (FR-017).

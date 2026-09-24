# Specification Quality Checklist: What Survives a Restart

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-09-24
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

- Two passes were made. The first named the files each fact would be written to and the
  in-memory dictionaries each is lost from; both were taken out, because they are the
  plan's business and naming them here would decide it. FR-024 keeps the one distinction
  that is the person's — a draft belongs to the window, not to the daemon — because that
  is about which machine remembers, not about how.
- FR-027 and the closing paragraph of "Why this feature exists" are what bound the scope.
  Without them this reads as a request to make live state durable, which it is not: a
  question whose runtime has gone stays unanswerable.
- The one judgement made without asking: unsent drafts are the window's and are not shared
  between surfaces. The alternative — the daemon holding them, so a draft started on the
  phone appears on the Mac — is a larger feature with a sync question in it, and nothing in
  the request asked for it. Recorded in Assumptions and in FR-023/FR-024 so it is a
  decision rather than an oversight.

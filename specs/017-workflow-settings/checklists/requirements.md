# Specification Quality Checklist: Workflow Settings

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

- Three clarifications were settled with the reader before drafting rather than left as
  markers: which settings ship (permission mode, runtime, model), where a change made in the
  app lives (written into the file), and what clicking a row opens (a detail view with the
  settings changeable). They are recorded in the spec's Clarifications section.
- The spec names front-matter key names (`permission-mode:`, `runtime:`, `model:`) in
  Assumptions only. This is deliberate and matches 008: the workflow file is a surface a person
  writes by hand, so its shape is part of the product rather than an implementation choice. The
  Functional Requirements themselves stay behavioural.
- FR-021 amends FR-032 of 008, which forbade the project page changing a workflow at all. The
  amendment is narrow — settings yes, triggers and prompt body still no — and stated in both
  places.
- FR-008 is the requirement the feature turns on: a permission mode the runtime does not offer
  refuses rather than falls back, because every fallback is more permissive than what was asked
  for and nobody is watching when a workflow fires.

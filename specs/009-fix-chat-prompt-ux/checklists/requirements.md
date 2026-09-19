# Specification Quality Checklist: Prompt Controls, Project Navigation, Scroll-to-Bottom, Remembered Mode, and Unseen File Requests

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-09-19 · **Revised**: 2026-09-19 (User Stories 2, 3, 6 and 7 added)
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

- Validation run 1 flagged two phrasings that leaked implementation ("option capsules", "carried by the daemon"); both were reworded to user-facing language. Run 2 passes all items.
- No [NEEDS CLARIFICATION] markers were used. One decision was taken by informed default and recorded in Assumptions rather than blocking: the mode preference is remembered **per runtime**, not per folder or per project. If per-project memory is wanted, raise it in `/speckit-clarify` before `/speckit-plan` — it changes FR-015 and the Mode preference entity.
- **Revision, 2026-09-19**: a fourth bug was reported after planning — clicking a project in the sidebar does not take you to the project page when you are inside one of its conversations. Folded in as User Story 2 at P2, with FR-021 through FR-025 and SC-007. The scroll and mode stories moved down to P3 and P4: an existing control that silently does nothing outranks two affordances that are merely absent. Re-validated against all 16 items; all still pass. `research.md` §2 and `plan.md` were updated in the same pass, so the design artifacts do not lag the spec.
- **Revision 2, 2026-09-19**: a fifth item was reported — an agent that shows a file while the window is looking elsewhere tells nobody. Folded in as User Story 5 at P5, with FR-026 through FR-031 and SC-008/SC-009. P5 is a statement about frequency, not about whether it should be done. Two copy changes requested in the same message ("running" → "working", "finished" → "complete") were applied directly to the code and are deliberately **not** in this spec: they change no behaviour and have no acceptance criteria worth writing. Re-validated against all 16 items; all still pass.
- **Revision 3, 2026-09-19**: a sixth item — option controls on a live agent do not respond until the runtime answers. Folded in as User Story 3 at P3, with FR-032 through FR-037 and SC-010. The scroll, mode and show-file stories moved down to P4, P5 and P6. P3 because it is the same surface as Story 1 and the same feeling of a control you cannot trust, but the control is present and does eventually work. Re-validated against all 16 items; all still pass.
- **Revision 4, 2026-09-19**: a seventh item — a question whose whole answer is one choice takes two clicks, a radio and a Send, while a permission question from the same agent is already one click on buttons. Folded in as User Story 7 at P7, with FR-038 through FR-043 and SC-011. Last by value, not by cost: it is the cheapest item here and the most frequent things sit above it. Re-validated against all 16 items; all still pass.
- Items marked incomplete require spec updates before `/speckit-clarify` or `/speckit-plan`

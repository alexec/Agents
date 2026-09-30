<!--
Sync Impact Report
- Version change: 1.2.0 → 1.2.1
- Modified principles: none; Governance renewal wording clarified
- Added sections: none
- Removed sections: none
- Follow-up TODOs: none
-->

# Agents Constitution

## Core Principles

### I. Spec-Led Feature Work
Every feature MUST be described by a specification with acceptance criteria before design
or implementation begins. The workflow MUST resolve open questions, record a plan and
ordered tasks, and implement against those tasks. This keeps feature scope reviewable and
connects changes to the user's stated need.

### II. Capability-Driven Runtime Integration
Runtime behavior MUST be based on capabilities the runtime advertises, not runtime identity
or assumptions about a vendor. Protocol extensions the app does not support MUST be refused
and logged. Runtime integrations MUST preserve the app's visible contracts for sessions,
tools, and user interaction.

### III. Scoped Access and User Control
An agent MUST only read, write, or act within the folders and capabilities granted to its
session. Writes and other permission-gated actions MUST use the app's permission flow.
Questions, escalations, and confirmations MUST reach the user through app-owned interaction
surfaces. These boundaries keep work observable and under the user's control.

### IV. Work Must Be Inspectable
Changes, command output, tool activity, and relevant file locations MUST be presented in the
conversation or its associated file view. Durable records MUST retain enough information to
understand what happened, while avoiding estimates presented as runtime-reported facts.
Visible work makes agent activity reviewable and helps the user decide what to do next.

### V. Documentation and Quality Travel with Features
Each feature specification MUST identify documentation pages it adds or changes, and the
documentation MUST be updated with the feature. Changes MUST meet the repository's quality
gates, including treating warnings as errors where configured and keeping generated artifacts
consistent with their sources. This keeps the shipped behavior and its explanation aligned.

## Project Constraints

The macOS app and its daemon MUST use the project architecture and build setup documented in
`README.md` and `docs/`. The daemon is the sole writer of its persisted agent state. Changes
to generated project files MUST be made through their declared source of truth. Agents and
runtime helpers MUST not read or write user-home configuration outside the folders granted
to the session.

## Development Workflow

Feature work MUST follow the Spec Kit sequence documented in `README.md`: specify, clarify,
plan, generate tasks, and implement. A specification's Docs section MUST list affected docs
pages. Before a change is considered complete, relevant build, test, and documentation checks
MUST pass; any check that cannot be run MUST be identified with the reason. Reviews MUST
verify acceptance criteria, access boundaries, runtime capability handling, and documentation
impact for the changed behavior.

## Governance

This constitution governs feature specifications, plans, implementation, and review. For
these rules, the project owner is the person accountable for project direction and repository
decisions. An amendment MUST update this file, explain the change in the commit or review
description, and receive the project owner's explicit approval, recorded in the review or
commit description, before it takes effect. The version MUST follow semantic versioning:
MAJOR for incompatible changes to principles, MINOR for added principles or materially
expanded requirements, and PATCH for clarifications that do not change obligations. Each
amendment MUST update the last-amended date.

Higher-priority system, developer, and user instructions take precedence over this
constitution. Project-specific guidance MAY add detail or stricter requirements, but MUST
NOT silently weaken this constitution. When project guidance conflicts with it, the conflict
MUST be recorded and resolved by the project owner before the affected work proceeds.

Reviewers and implementers MUST assess compliance during planning and review. A deviation
MUST record its reason, scope, accountable owner, and expiry date, and MUST receive the
project owner's explicit approval recorded in the review or commit description. Approval
expires automatically on that date unless the project owner renews it before expiry. Any
renewal MUST record a new expiry date with the renewed approval. The owner MUST review the
deviation by its expiry date and either close it or renew the recorded approval.

**Version**: 1.2.1 | **Ratified**: 2026-09-29 | **Last Amended**: 2026-09-29

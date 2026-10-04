# AGENTS.md

## Context routing

- **For the project's purpose and setup:** READ `README.md`.
- **For architecture, terminology and decisions:** CONSULT `docs/`.
- **For a task a skill covers:** USE the skill in `.agents/skills/`.
- **When a task calls for a specialist perspective:** ADOPT a persona from `.agents/personas/`.

## Keeping the three clients in step

- **Three clients draw the same product:** the Mac window (`App/`), the Remote on iPhone and iPad (`Remote/`), and the web page (`Web/`). `Shared/UI` is drawn by both the window and the Remote.
- **A change to any client's UI** (`App/Sources`, `Remote/Sources`, `Shared/UI` or `Web/src`) says, in its commit, what **each of the other two** does about it, one line each:
  - the same change in this branch: `remote: same`;
  - a parity issue filed: `web: #NNN`;
  - left out on purpose: `mac: by design (no swipe on Mac)`.
- **For example,** a Mac sidebar change ends with `remote: #226` and `web: same`; a web-only fix ends with `mac: same, remote: same` when both already do it. A change to docs only says `mac: docs only, remote: docs only, web: docs only`.
- **The table of where each client stands** is `specs/071-web-remote/walks/parity.md` (Mac / Remote / web, a row per screen and feature). A parity line that changes a row updates it in the same branch.

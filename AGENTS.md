# AGENTS.md

## Context routing

- **For the project's purpose and setup:** READ `README.md`.
- **For architecture, terminology and decisions:** CONSULT `docs/`.
- **For a task a skill covers:** USE the skill in `.agents/skills/`.
- **When a task calls for a specialist perspective:** ADOPT a persona from `.agents/personas/`.

## Durable data

- Store data in the project itself when possible.
- When important long-term data cannot safely live in the project, store it on disk in `~/.agents` when safe. Do not rely on an agent's memory for data that can safely be stored there.

## Keeping the web page in step

- **A change to the window's or the Remote's UI** says, in its commit, what the web page (`Web/`) does about it: the same change in the same branch, a parity issue filed, or `web: by design` with the reason. The table of where the page stands is `specs/071-web-remote/walks/parity.md`.

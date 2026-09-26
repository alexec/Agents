# 059 · US4 walk (2026-09-26)

A scratch app (`/tmp/run-059`) with its own personal home, pointed at `walk/fixture-server.py`.

- **Clash** (`e-clash.png`): the scratch home has a skill of the person's own called `nested`,
  with no lock entry. The catalogue's `nested` opens with:
  - the orange "You already have a skill called nested in …/.agents/skills. You made it (it
    didn't come from here), so the app won't replace it.";
  - the blue "Adding to work would work", because the project had no `nested`;
  - **Reveal yours** in place of Add.

  The person's SKILL.md was unchanged afterwards.
- **Offline** (`e-offline.png`): after `POST /_down`, a new search shows "Can't reach …" with
  the explanation and **Try again**, and keeps the query. It names `127.0.0.1` only because the
  stand-in is local; live, the host is skills.sh.
- **The daemon killed mid-add** (quickstart §3 step 13, over the socket), with
  `AGENTS_TEST_CATALOG_PAUSE=afterRename`:
  - mid-add, `plain` was in place and `catalog-pending.json` existed;
  - `kill -9` on the daemon; the app started a new one;
  - that daemon logged `catalog: undid an unfinished add of plain`;
  - no folder and no journal were left (SC-003).
- **Fixed after the first shots:**
  - The detail's notes were cut to one line; they wrap now, and the left column scrolls.
  - The **added** mark showed on a catalogue row whose name matched a skill of the person's own;
    it now counts only skills a lock names.

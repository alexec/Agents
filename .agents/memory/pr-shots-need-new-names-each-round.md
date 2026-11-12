---
name: pr-shots-need-new-names-each-round
description: A second round of pr-shots.sh under the same file names shows Alex the old pictures; GitHub caches images by URL. Name each round's files anew.
metadata:
  type: feedback
---

`pr-shots.sh` replaces a PR's files on the `screenshots` branch, but the PR body's links stay the same URL, and GitHub's image cache keeps serving the old picture. On #4933 (2026-11-12) Alex said "I don't see these changes on the screenshot in the PR" after the sixth round, though the branch held the new files.

**Why:** a reviewer judging a look sees an old version and the round is lost.

**How to apply:** give each round's files a new name (`r2-mac-empty.png`, `r3-…`) and relink the PR body. When the change is subtle, add a before-and-after close-up as well. Related: [[walk-what-you-ship]].

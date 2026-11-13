---
name: never-link-node-modules-into-a-worktree
description: A symlink from a worktree's Web/node_modules to the main checkout's lets the AgentsHost build's npm ci empty the main checkout's packages
metadata:
  type: feedback
---

Do not link `Web/node_modules` in a worktree to the main checkout's `~/Agents/Web/node_modules` to run the web tests. The `AgentsHost` build runs `scripts/web.sh dist`, which runs `npm ci` in the worktree's `Web/`: `npm ci` emptied the link's target, the main checkout's packages, and put a real folder in the worktree (#5137, 2026-11-12).

**Why:** the main checkout lost every web package until `npm ci --ignore-scripts --no-audit --no-fund` ran there again.

**How to apply:** in a worktree with no `Web/node_modules`, run `npm ci --ignore-scripts --no-audit --no-fund` in its own `Web/` (as `scripts/web.sh test` does), or run `scripts/web.sh test`. If a link was made, repair the main checkout with the same `npm ci` there.

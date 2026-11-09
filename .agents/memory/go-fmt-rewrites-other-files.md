---
name: go-fmt-rewrites-other-files
description: Go/scripts/go.sh fmt on a package rewrites files on main that are not gofmt-clean; restore the ones you did not touch
metadata:
  type: project
---

`Go/scripts/go.sh fmt ./internal/agentsd/` (and lineage, githubmcp) also rewrote six files that no change touched (2026-11-08, #4172): some files on main are not gofmt-clean for the container's Go.

**Why:** a lane that commits them widens its diff, takes other areas' files and can conflict with their lanes.

**How to apply:** after `go fmt`, run `git status --short` and `git checkout --` each file you did not change.

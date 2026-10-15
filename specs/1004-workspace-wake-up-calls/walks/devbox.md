# Walk: a wake-up call on the devbox (2026-10-14)

## Set-up

- **Control plane:** a scratch one from `run-app` (`launch.sh --slug w1004 --lan --no-build
  --no-window --control-env AGENTS_WORKSPACE_COMMANDS=<debug workspace-commands>`), built
  from this branch. The Linux host was built from this branch (`scripts/build-linux-agentsd.sh`).
- **Box:** the `agents-devbox` container from `test-servers`, its clock on UTC.
- **Driver:** `Walk1004LiveTests`, as #691's walk. It adds the box over ssh, gives its host the
  workflow in [box-workflow.sh](box-workflow.sh) (due once a day at 05:00 UTC, which is 22:00
  here), links it to a docker provider for its container, and sets **Stop when idle** to 1 minute.

```sh
AGENTS_WALK1004_URL=$CONTROL_URL AGENTS_WALK1004_HOME=$ROOT/control AGENTS_WALK1004_ROOT=$ROOT \
AGENTS_WALK1004_TOOL="build/DD/Build/Products/Debug/Agents Host.app/Contents/Helpers/agents-control" \
scripts/build-cache.sh swift test --package-path Packages/ControlPlane --filter Walk1004
```

The app restarted during the walk and stopped the test process. The scratch control plane and
the box went on, so the rest was read from `control.log`, the stored host record and the box's
`workflows/list`.

## What happened

| Time | Seen |
|---|---|
| 21:46:09 | The box joined over ssh and was linked. Its host sent its next workflow, which was kept on the link: `schedule: {at: 05:00Z, workflow: "Wake-up walk"}` (FR-002, FR-003) |
| 21:47:24 | Stopped as idle after 1 minute |
| 21:55:01 | `wake-up call for w1004-devbox: Wake-up walk due at 05:00:00 +0000`: 5 minutes early, as no start had been measured (FR-004) |
| 21:57:04 | Online. The box has no systemd, so the control plane started agentsd over ssh after 2 minutes: `ok in 123s`. `measuredStartSeconds: 123` was kept, so the next call comes 4 min 3 s early |
| 21:58 | Not stopped, though idle for a minute: it was started for the workflow (FR-005) |
| 22:00 | The host's own clock fired the workflow (FR-001). It was refused there, as "Claude is not installed": the box has no runtime for a scheduled agent. That is the box, not this feature. Its next time is 05:00Z tomorrow |
| 22:01:05 | Idle a minute after the run: stopped again. `wokeFor` is 05:00Z today, so it is not started again for it (FR-006) |

## Found and fixed on the way

A host says it is idle as it connects. A start isn't done yet at that moment, so the control
plane didn't begin the idle count, and nothing began it later. In the walk, the count began
only because the host's next due time changed at 22:00. A host started by hand, or by a
wake-up call, and then left idle would never have been stopped. This came from #691. Now a
start that ends well begins the count. Test: `aHostIdleAsItsStartEndsIsStoppedAfterItsIdleTime`.

## Not walked here

- **The screens.** The walk ran with no window. The words come from `OfflineWords.wakeLine`
  and the web's `wakeLine`, which tests cover, and from the row's `wakeAt` and `nextWorkflow`,
  which this walk saw in the stored record. The Mac's Hosts row and switch, and the strip on
  the Remote and the web page, are built and their builds and tests pass.
- **The switch off.** `theSwitchOffMakesNoWakeUpCall` covers it.
- **A run that does work.** Claude isn't signed in on the box.

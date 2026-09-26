# US2 walk — first run, Run one on this Mac (2026-09-26)

Build `494d6688`, plus the card-height fix in the commit that adds this file. Fresh
scratch roots `/tmp/run-fr` and `/tmp/run-fr2`; the windows were launched behind with
`env -i … open -n -g`, and buttons were pressed by AX on the window's pid.

- **Frame A** ([us2-a-first-run.png](us2-a-first-run.png)): with no control plane and
  nothing on the root, the window shows the one question and no sidebar or toolbar. **No
  `agentsd` was started.** The first build stretched the cards to the window's height;
  fixed.
- **Frame C** ([us2-c-connect.png](us2-c-connect.png)): Connect… lists control planes
  found by Bonjour. It found the real bridge on this network, "Alex's MacBook Air". Connect
  says plainly that pairing with another machine isn't built yet; Cancel goes back.
- **Frame B** ([us2-b-setting-up.png](us2-b-setting-up.png)): Run One Here shows the four
  steps. Set-up took about a second, so it was caught only by screenshots every 0.1 s.
- **After** ([us2-after.png](us2-after.png)): the window is on the empty project list,
  well inside SC-003's one minute.
  - Two launchd jobs were running, `com.alexecollins.agents.{control,host}.scratch-<hash>`,
    from plists in `<root>/control`.
  - The window was in `clients.json` as the operator "This Mac".
  - The host was in `hosts.json` as `mac`.
- **Restart:** the window was quit and opened again. It went straight to its projects (no
  first run), with still only one `agentsd`, launchd's.
- **Kept running:** the host was killed (51808) and launchd restarted it (52590). It
  rejoined the control plane by itself.
- **Clean-up:** both jobs booted out, both windows quit, the `controlRoot:/tmp/run-fr*`
  defaults keys deleted, and both roots removed.

## Not walked

- The real `SMAppService` path, which registers under Login Items. It is used only on
  the ordinary root, and registering it from a branch build would put jobs pointing into
  this worktree on Alex's Mac. It waits for the move (US6), with his go-ahead.
- The Login Items approval wait (`.requiresApproval`). This is the same reason: a scratch
  root never needs it.
- Logout and login. launchd's `RunAtLoad` covers it, but it wasn't tried.

# Quickstart: walking 058 on a scratch root

Never on the real root, never on Alex's paired devices. Use the run-app skill for the window
and test-servers for the devbox.

```sh
S=/tmp/cp-walk; rm -rf $S; mkdir -p $S/control $S/host
DD=<the worktree's DerivedData>/Build/Products/Debug

# 1. Control plane, on its own port and without Bonjour or CloudKit
AGENTS_CONTROL_PORT=8799 AGENTS_CONTROL_NO_BONJOUR=1 AGENTS_CONTROL_NO_MAILBOX=1 \
  $DD/agents-control.app/Contents/MacOS/agents-control --root $S/control &

# 2. A host code, and the host dialling out
agents-control --root $S/control code --host            # prints a code
$DD/Agents.app/Contents/Helpers/agentsd --root $S/host --serve --control '<code>' &

# 3. A client code for the scratch window, as operator
agents-control --root $S/control code --client operator
```

4. Launch the scratch window (run-app) with `AGENTS_CONTROL=<code>`; it pairs and shows the
   host `mac` with no projects.
5. Add a project over the socket-free path (the window's Add project), start a Claude turn,
   answer a question, stop it. Screenshot each.
6. Kill the control plane for 30 s: the turn carries on (check the host's log), the window says
   it can't reach the control plane, then catches up on restart.
7. Devbox: `hosts/install` from the window's Add a server with the devbox destination; start a
   turn there from the same window.
8. Fake device: pair a second client as `device` with a small Swift script over TLS-PSK (the
   test-servers skill's helper), call `credentials/lend`, `hosts/install`, `clients/list`:
   each is refused; call `agents/list`: every host's agents come back.
9. Measure (R10): shell echo round trip, direct socket vs channel vs devbox.
10. Stop everything; `rm -rf $S`.

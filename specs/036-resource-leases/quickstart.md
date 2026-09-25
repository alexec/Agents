# Quickstart: Proving Resource Leases Work

Run everything from the feature's worktree. Never use the shared checkout or the real daemon.
Build Xcode schemes one after the other, with plugin validation skipped.

## 1. The rules, in unit tests

```sh
cd Packages/AgentsKit
swift test --filter 'LeaseBookTests|LeaseStatusTests|AppServiceTests|BriefingTests'
```

Expected:
- `LeaseBookTests`: two requests at the same instant give exactly one holder (SC-001). The line
  is served in asking order. A re-request by the holder extends and never queues. A 600-minute
  request is capped at 240 and says so. Names differing only in case or spaces collide. `lapse`
  expires, warns once, and hands over. `drop` releases everything and leaves every line.
- `LeaseStatusTests`: the chat line and card mark match data-model §LeaseStatus, and are `nil`
  for an agent with nothing.
- `tools/list` includes `lease_resource`, `release_resource` and `list_resources`. The briefing
  contains the leases paragraph.

## 2. The daemon, with fake runtimes

```sh
swift test --filter LeaseTests
```

Expected (each is one test, with `LeaseLimits` shortened through the test clock):
- A holds, B waits with its call open, A releases, and B's call returns "is yours now" within 1 s.
- B's call reaches the wait limit and returns "still in line". A releases, and B receives the wake
  prompt `from: .app` within 5 s, with the lease already its own (SC-002).
- B has a turn in flight when the lease arrives. The wake prompt waits in its queue behind that
  turn.
- A is stopped, and then archived: its leases pass on and its places are gone. An open call from
  a stopped waiter returns "you were stopped".
- Restart: leases and lines survive with the same expiry. A lease whose expiry passed while the
  daemon was down is released during load and the next waiter is woken (SC-003).
- The person ends A's lease. A's next `list_resources` reply begins with the notice.
- B can't run (runtime removed): the lease is passed on and B's transcript says why.
- 20 concurrent `leases/lease` calls on one name give one holder and a line of 19.

Then the whole suite on this branch and on main, following the flaky-suite rule (compare full
runs on both before blaming the branch).

## 3. End to end on a scratch daemon (run-app skill)

Launch a scratch root with the run-app skill. The Resources row sits above Spending in the
sidebar.

1. **Page, empty**: open Resources. Screen, each available simulator and each browser are listed
   as free. Screenshot.
2. **Two agents, one simulator**: start agent A with "Lease the first simulator from
   list_resources for 5 minutes, then wait 90 seconds, then release it and finish." Start agent B
   with "Lease the same simulator, say when you have it, release it and finish."
   - The page shows A holding it and B in line, first. Screenshot.
   - A's chat line reads "Holding … (5 min left)". B's reads "Waiting for …, held by “A”, 1st in
     line". Both rows carry their marks. Screenshot each.
   - B's call returns "still in line" after 45 s, and B ends its turn.
   - A releases. Within 5 s B is started again with the "is yours now" prompt, drawn under
     "Agents asked", and finishes. Both lines clear. Screenshot.
3. **The person**: confirm a free row on the page has no Take button. Have agent C lease the
   screen and agent D ask for it. End C's lease from the page: D is granted it, and C's next
   lease call starts with the notice. Have C ask again, then remove C from the line with ✕.
   C's next call says it is not in line.
4. **Restart**: with a lease held, stop the scratch daemon by the pid in its `daemon.lock` (never
   by name), relaunch, and confirm the page shows the same expiry.
5. **Phone**: build Remote for the generic simulator only, to prove it compiles. How the line
   and card look on a real phone is Alex's to check.

Record, for each runtime available, whether a 45 s wait came back as "still in line" or the
runtime gave up first. Put the result in the tasks file's final note.

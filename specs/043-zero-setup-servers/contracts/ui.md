# Contract: screens

Words follow the app's voice: sentences, the server by its label, no jargon beyond "token".

## § 1 Settings ▸ Servers — "Signing in on servers" (FR-009–FR-011, US2)

A section above the server list.

```
Signing in on servers
  Claude   ● Works · added 25 Sep · last worked today        sk-ant-oat…a3f9   [Replace] [Remove]
           Used only by agents on servers. Agents on this Mac use this Mac's own sign-in.
           Any program running as you on a server can read it while an agent runs there.
```

Empty state: a secure field "Paste a Claude token", the line "Make one with `claude setup-token`
on this Mac, or use an API key from console.anthropic.com", and [Save].

On Save: spinner ≤ 10 s, then one of "Works", "Claude refused this token" (field stays for another
paste), "Can't check right now — saved, and it will be tried on the next server agent".

## § 2 Per server, in the same pane (FR-014)

Each server row gains: `Toggle("Use this server's own sign-in only")`, and a Claude status line:
"Claude: ready (installed by Agents)", "Claude: the server's own", "Claude: installing… 60%",
"Claude: couldn't install — <sentence>" with [Try again], "Claude: update waiting for a turn to end".

## § 3 The ask, in place (FR-015, US2-5)

When a start on a server gets `credentialWanted` with `offered: false`, the start form (or the
prompt bar for a relaunch) shows a card instead of starting:

```
Claude on devbox needs a token
[ secure field                                   ]  [Save and start]
Make one with `claude setup-token` on this Mac.         [Cancel]
```

Save stores it as § 1 does, lends it, and repeats the start with the same `sendID`.

## § 4 Set-up checklist (037's Add a server) (US1-1, FR-006)

A new step after "Start Agents on devbox": **"Install Claude"** with a determinate bar during
the download and "Setting up Claude…" during `npm ci`. Shown when a Claude token is in Settings
(FR-002); otherwise a quiet line "Claude will be installed the first time you start it here".
Failure shows the § 4 sentence of contracts/ssh.md and the step's [Try again]; the rest of the
server stays usable.

## § 5 Rebuilt server sheet (FR-017, US3-1)

In place of 037's "host key changed" refusal:

```
devbox has a new identity
This happens when a server is rebuilt. If you didn't rebuild it, someone may be
pretending to be it — cancel and check.

Before   SHA256:Qm1…old
Now      SHA256:Zx9…new

                               [Cancel]  [This server was rebuilt]
```

The default button is Cancel. The destructive-style button runs contracts/ssh.md § 5 and a
normal set-up.

## § 6 Gone projects (FR-019, US3-4)

In the host group, a project whose folder is no longer on the server shows its name greyed with
"Gone from devbox" and a [Remove] button; its agents' history stays readable until removed. Never
the offline strip.

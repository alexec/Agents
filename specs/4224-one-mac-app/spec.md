# One Mac app (#4224)

Alex, 2026-11-09. On the Mac, Agents becomes one app. The window and Agents Host go into a
single Developer ID download, named **Agents**, that is not in the Mac App Store. The
iPhone and iPad Remote stay in the App Store. We will not reverse this, so we also remove
what only the split needed.

## Goals

1. **It works when you open it.** A person downloads Agents, opens it and starts an
   agent. The app asks no "where should your agents run?" question, needs no code, no
   sign-in and no control plane somewhere else.
2. **You can connect a control plane later.** Hosted at agentloops.dev or a self-hosted
   one, from Settings, when the person wants it. They can also go back to "this Mac only".
3. **One app to look after.** One install, one update, one item in Login Items, one
   menu bar item.
4. **Less code.** No Store target, no sandbox gate, no first-run frames, no window
   for the host, and no pairing of a window to the host on the same Mac.

## Not goals

- A Mac App Store build of any kind. A person who has no agents on their Mac uses the
  web page (#3403, Principle 1).
- Moving a local control plane's records to Hosted. Agents' records live on the host,
  so they stay where they are.
- A new architecture. The daemon (`agentsd`) and the local control plane stay launch
  agents. Closing or quitting the window stops no agent.

## Principles (direction.md, #3403)

- **Principle 1 (nothing relies on the Mac):** kept. The local control plane is for this
  person only. The web page is still a full client.
- **Principle 2 (Hosted is the default way in):** left out for the Mac download only.
  The Mac download's default is a control plane on this Mac, because Alex wants it to
  work with nothing remote (2026-11-09). Hosted is still the default for a person who
  starts in a browser.
- **Principle 3 (everyone signs in):** left out for the single-user Mac shape (Alex,
  2026-11-09). That shape has one person, who owns the Mac. Sign-in comes when the person
  connects Hosted or a self-hosted control plane.
- The docs child updates direction.md to say this.

## What the person sees

### Download and first open

1. The person downloads `Agents.dmg` (#2145 says where it is published) and drags
   Agents to Applications.
2. They open Agents. With no prompt, the app does what Agents Host's **Run It Here**
   does today (`HostModel.runHere()`):
   - It makes the control key.
   - It registers the two launch agents (the control plane and this Mac's host) with
     `SMAppService`.
   - It starts them.
   - It joins this Mac's host to that control plane.
3. **The window pairs itself.** The app holds the control key, so the window gets its
   own client membership locally: no code to copy, no Bonjour wait, no paste. The lane
   picks the mechanism, for example a one-time code that the control job leaves in the
   app group, as it does for agentsd today. The window must still be a listed client,
   so that agentsd's checks stay as they are.
4. The main window opens on the empty session list, with the usual first step: choose
   or sign in to a runtime, then start an agent.

```
┌ Agents ────────────────────────────────────────────┐
│ ▸ Folders            │                             │
│   + Add a folder     │   Start your first agent    │
│                      │   [ Choose a folder… ]      │
│                      │   Runtime: Claude ▾  Sign in│
│                      │                             │
└────────────────────────────────────────────────────┘
```

If a step fails, the window shows one line with **Try Again** and **Show Details**, in
the place where the session list would be. For example: macOS turned off the login item,
or the control plane did not start. Login Items needing approval in System Settings is
one of these: the line says so and has **Open Login Items**.

### The menu bar item

The menu bar item stays. It shows that agents keep running when no window is open.

```
◉ Agents
  2 working · 1 needs you
  ───────────────────────
  Open Agents
  Pair a Phone or iPad…
  Open in Browser
  ───────────────────────
  Settings…
  Quit Agents          (agents keep running)
```

- **Quit Agents** quits the window and the menu bar item. The launch agents keep running,
  as they do today when you quit Agents Host.
- Opening the app again (Dock, Spotlight, the menu bar) opens the window.
- At login, macOS starts the launch agents and the menu bar item. The window does not open.

Decided: one menu bar item for the whole app, with these items, because it is Agents
Host's menu with the window's counts added. Alex can overrule.

### Where Agents Host's controls go

The Agents Host window (frame L) is removed. Each control moves into the window's
Settings, or goes away:

| Agents Host today | In the one app |
|---|---|
| First choice: Run It Here / Join one elsewhere | Gone. First open is Run It Here. Join is **Settings ▸ Control plane ▸ Connect…** |
| This Mac card: status, **Repair**, **Open Login Items** | **Settings ▸ Machines ▸ This Mac**, at the top, beside Sleep and Updates |
| **Try Again** on a failed join | The same line, in Settings ▸ Machines ▸ This Mac |
| **Serve Agents to browsers on this Mac** toggle, **Open in Browser** | Settings ▸ Control plane, beside the browser card that is already there (`ControlBrowserCard`) |
| **Pair a Window or Phone…** and its sheet | The pairing sheet that Settings already has (`PairDeviceSheet`). The "window" choice goes, because the window pairs itself; it stays for a window on *another* Mac |
| CONTROL PLANE card: Where, Running at, **Restart** | Settings ▸ Control plane, which already shows **Restart** |
| **Move to Another Machine…**, forwarding rows | Settings ▸ Control plane ▸ Move… (the same flow) |
| Store: On this Mac / In a bucket, **Check**, **Switch Store…** | Settings ▸ Control plane ▸ Store |
| Diagnostics: **Copy**, **Save…**, **Show Logs** | **Help ▸ Diagnostics** (menu items) and Settings ▸ Machines ▸ This Mac |
| Move strip (move an existing set-up) | Gone after migration (see below) |
| Menu bar: Open Agents Host, Pair…, Open in Browser, Quit | The menu bar item above |

Also removed from the window: the first-run frames K and K2 (`FirstRunView`),
**Get Agents Host…**, the `NoMacHostNotice` and the paste-a-code steps in
`set-up-on-this-mac.md`.

### Connecting a control plane

**Settings ▸ Control plane** shows where this Mac's control plane is:

```
Control plane
  ● On this Mac              [ Connect to Another… ]
    Running · 1 machine · 2 devices
    Store: On this Mac ▾
    Serve Agents to browsers on this Mac   [on]
```

**Connect to Another…** opens a sheet that has two choices:

- **Sign in to agentloops.dev** (Apple, Google, GitHub).
- **Use a code** from a self-hosted control plane.

The sheet then says what happens before it does it:

> This Mac's agents will report to *acme.agentloops.dev*. Your sessions stay on this
> Mac. Your iPhone, iPad and browsers must pair again. The control plane on this Mac
> stops.

After **Connect**, the host leaves the local control plane and joins the new one (what
**Join one elsewhere** does today). The window signs in to it, and the local control
plane's launch agent stops. **Use This Mac Only** in the same place goes back: it starts
a new local control plane and the window pairs itself again.

Decided: connecting does not copy the local control plane's records (devices, codes,
policy), because a single person has almost none, and their sessions are on the host,
not the control plane. Alex can overrule.

## Under the hood

- **One target.** Merge `AgentsStore` into `AgentsHost`, keep its bundle ID
  (`com.alexecollins.agents.host`), and rename the product to **Agents**. The window
  can link all of `AgentsKit`. "The window starts no agent program" stays as a rule
  in the code (the daemon owns agents), but the sandbox no longer enforces it.
- **Simplify what the sandbox forced.** For a folder on this Mac, the window opens
  Finder and files itself. A host still does this for a folder on another machine.
- **Updates.** agentsd's self-update (`Go/internal/agentsd/selfupdate.go`) installs the
  new app. It swaps `Agents Host.app` for `Agents.app` once, so that an alpha install
  moves across with no step from the person. How (#4225):
  - A release carries `Agents-<version>.zip` (`Agents.app`), which Agents updates from.
    It also carries `Agents-Host-<version>.zip`: the same signed app, named
    `Agents Host.app`. An Agents Host updates itself from that zip, as it does today.
  - The first time a release's agentsd runs from an `Agents Host.app`, it renames the app
    to `Agents.app` beside it and restarts the launch agents (`takeNewName`). The login
    items follow the bundle (#4130), so they run from the new name. When something else
    is named `Agents.app` there (the App Store window, in `/Applications`), the app keeps
    its old name.
  - The program in the bundle keeps the name `Agents Host` (`EXECUTABLE_NAME`). Each
    login item was registered with `BundleProgram Contents/MacOS/Agents Host`, so the
    program stays at that path in every copy that an update puts in place. A person sees
    `CFBundleName`, which is Agents.
- **Sign in with Apple:** the one app has no `com.apple.developer.applesignin`
  entitlement, which a Developer ID app gets only with a provisioning profile. The window
  never called the native Apple sheet (`ASAuthorizationAppleIDProvider`), so nothing is
  lost. #4228 adds the entitlement and a profile if its sign-in to agentloops.dev uses that
  sheet.
- **Remove:**
  - the `AgentsStore` target;
  - `App/Agents-Store.entitlements` and `App/Info-Store.plist`;
  - `scripts/check-store-window.py`;
  - `release-store.sh`'s Mac half and the Mac half of the `testflight` job;
  - the Mac half of `app-store.yml`;
  - the Mac half of the Universal record (#659 becomes iOS only).
- **Release.** `release-host.sh` makes `Agents-<version>.dmg` and `.zip`. The release
  notes for that version tell TestFlight people to delete the old Agents window.

## Migration for alpha people

- **Agents Host already installed:** self-update installs Agents. Its role (Run Here or
  Joined) and its control key stay. The window pairs itself when the role is Run Here,
  and signs in as usual when the role is Joined.
- **Old Store window still installed:** it still works as a client until it is deleted.
  Agents does not touch it.
- **Window preferences** in the old Store container are not carried across. This is an
  alpha, and the defaults are fine.

## Clients

- **Mac:** all of the above.
- **Remote:** copy only. "Agents Host" becomes "Agents" in `PairingView`. The App Store
  record becomes iOS only.
- **Web:** copy only. "Agents Host" becomes "Agents" in pairing, the Mac host notice and
  Desktop control. The page that this Mac serves does not change.

## Open questions

- The first-run line when macOS asks for approval in Login Items: can the app wait for it
  and then carry on by itself? (Lane B finds out.)
- Uninstall: does dragging Agents to the Trash leave the launch agents registered? If it
  does, do we need **Settings ▸ Machines ▸ This Mac ▸ Remove Agents from This Mac…**?
  (Lane A finds out.)

  **Answer (#4225): yes, they stay registered, so the command is needed.** A login item
  that `SMAppService` registered follows its bundle, not its path. ship.sh found this when
  it moved copies aside (#3521, #4130): launchd keeps starting a job from the copy that the
  item was registered from, while that copy is on disk, wherever it is. In the Trash, the
  copy is still on disk, so the control plane and agentsd keep running from
  `~/.Trash/Agents.app`. After the Trash is emptied, launchd cannot start them (exit 78,
  EX_CONFIG, every time it tries), and the items stay in System Settings ▸ General ▸ Login
  Items until the person turns them off. Only the app can unregister them
  (`SMAppService.unregister`, which `LocalServices.remove()` already calls). So **Remove
  Agents from This Mac…** goes in Settings ▸ Machines ▸ This Mac (#4227): it stops and
  unregisters both jobs, and then says that Agents can go to the Trash. This was not tried
  on a real install, because a try registers login items on Alex's Mac. #4227's walk
  checks it on a scratch copy, with `sfltool dumpbtm` before and after.
- When the role is Joined, can the window use the host's membership to sign in with no
  step? (Lane D finds out.)

## Plan

Epic #4224. Its sub-issues and their "blocked by" links are the plan:

| Step | Issue | What |
|---|---|---|
| 1 | #4225 | One target, named Agents (also commits this spec) |
| 2 | #4226 | First open: everything here, the window pairs itself |
| 2 | #4227 | Host controls into Settings and the menu bar (waits for Alex) |
| 3 | #4228 | Connect to Hosted or self-hosted, and back (waits for Alex) |
| 3 | #4229 | Remove the Store window, its gate and its jobs |
| 4 | #4230 | Docs, run-app, and the copy in all three clients |

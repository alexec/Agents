# 058 · #61 · Move to another machine (T126)

**Waiting for Alex's approval.** The look gate for Agents Host's *Move to another machine…*:
moving the running control plane from this Mac to a machine elsewhere, with every window,
phone and server staying paired (research R16). The way back, *Run It Here Again…* (T127),
uses the same sheet in the other direction and is drawn once these are settled.

Source: [wireframes.html](wireframes.html), in frame L's style. Open it with `#o` to `#t` to
see one frame. The PNGs beside it are rendered from it with headless Chrome.

## O · The way in

![The way in](o.png)

One new button, beside the address the control plane runs at, shown only while it runs here.

## P · 1. The key

![The key](p.png)

The other machine needs this control plane's key first. Agents Host saves it as one file and
the person copies it across: it is never sent anywhere (Alex's choice, R16). The command
starts the other machine empty, waiting for this one.

## Q · 2. Check the other machine

![Check](q.png)

Four checks before anything is told to anyone. The certificate must be publicly trusted:
a pin at a domain name would be refused by the window and the Remote (R15).

## Q2 · A check that fails

![Check fails](q2.png)

Each failure says what to do. Nothing has changed yet.

## R · 3. Tell everyone, and who knows

![Who knows](r.png)

*Tell Everyone* gives every member the new address beside this one. The list fills as they
reconnect. The person moves when they like (Alex's choice): anyone still to hear learns later
from this Mac. A build too old to follow is named. *Withdraw* takes the address back.

## S · 4. Moving

![Moving](s.png)

About a minute. Pairing and changes wait; agents carry on. *Cancel* puts everything back until
the other machine takes over.

## T · Afterwards

![Afterwards](t.png)

This Mac has joined the control plane elsewhere and is still a host there. A forwarding row
stays while anyone is still to hear, and goes by itself once everyone has.

## Open for Alex

- **Forwarding has no timer** (R16 default): it runs until everyone has heard or the person
  stops it. A limit (say 30 days) is easy to add.
- **Old builds can't follow** (R16 default): they are listed, and pair again afterwards.

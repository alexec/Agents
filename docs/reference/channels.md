---
diataxis: reference
devices: [mac, iphone, ipad]
description: Channel identities linked to people, so a chat or email message acts only as the person who approved it.
---

# Channels

A channel is a chat app or a mailbox that an MCP server brings in (#1223), such as Slack or
email. A message on it can start a workflow. A channel identity (a Slack user, an email
address) can be faked or given to someone else, so it acts as a person only once that person
has linked it (#1762, spec 736 FR-037).

## A message from an identity that is not linked starts nothing

- **The server names the sender.** A server's event that is a message carries `sender`:
  the channel (`slack`, `email`), the identity on it, and a name or email address when the
  channel knows them. An event with no `sender` is not a message, and runs as before.
- **The machine asks first.** Before the event is raised, the machine asks the control plane
  whom the identity is linked to (`links/check`). Linked: the event is raised, and names the
  person (`sender_user`, `sender_name`). Not linked, refused, or no control plane to ask:
  nothing starts, and the message is not tried again.
- **Its person is asked.** The first message from an identity that is not linked asks the
  person whose sign-in email is the sender's email (for email, the address itself). With no
  such person, the admins are asked, and they send it on to a person. **Only the person
  named approves a link**: an admin cannot link an identity to someone else.
- **One card at a time.** An identity has at most one request a day. A denied identity asks
  again only after a day. At most 50 requests wait at once.

## Email needs DKIM

A message from an email address acts only when the receiving mail server found a DKIM pass
signed by the address's domain, or a parent of it (`mail.example.com` signed by
`example.com`). A DMARC pass from SPF alone is not enough. Anything else is refused, and asks
for no link. The email server (`agents/email`) reads the result from the topmost
`Authentication-Results` header, which is the receiving server's.

## Links

A link is a channel, an identity on it, the person, and who approved it when. A person sees
and removes their own links; an admin sees and removes everyone's. A removed person's links
go with them.

## On the wire

`links/list`, `links/requests`, `links/approve`, `links/deny` and `links/remove`, with
`control/linkRequested`, `control/linkDecided` and `control/linksChanged`; `links/check` from
a machine on its channel 0 (`Packages/Wire/control.openrpc.json`). An admin's
`links/approve` on a request that names nobody says `for`, the person it goes to. Links are
kept in the control plane's store at `v1/links/<channel>/<sha256(identity)>.json`, and
requests at `v1/linkRequests/<request>.json`.

Channel servers still run on the machines whose workflows hear them. Running them on the
control plane itself (FR-036) is for the Channels milestone.

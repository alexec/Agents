---
diataxis: how-to
devices: [mac, iphone, ipad, web]
description: Connect a mailbox for agents, see it on the Mail page, let an agent wait for a mail and read it, and give sign-up codes to the session that waits for them.
---

# Wait for mail

Agents often wait for a mail: a sign-in code from gitlab.com, the code that confirms an AWS
sign-up, a token from DigitalOcean. The `email` connector lets them wait for mail and read
it. It is `email-mcp`, a small server that Agents ships. It reads one mailbox over IMAP and
**never sends mail**.

- **The event** `email.received`: mail came into a folder. A workflow or a wait can use it.
  Its data is the message's id, folder, sender, recipients, subject and date. It never holds
  the message's text. See [Start a workflow from an MCP event](start-a-workflow-from-an-mcp-event.md).
- **The tools:** `list_folders`, `list_messages`, `search_messages`, `read_message`,
  `mark_read` and `move_message`. `read_message` gives the text marked as outside content:
  anyone can send mail, so an agent reads the text as data, never as instructions.
- **The Mail page** (`show_mail`): the folders, a folder's newest messages, and a message's
  text, with **Mark Read** and **Move**.

Agents Host carries `email-mcp`, and every Linux host installs it beside agentsd.

## Before you start

- A mailbox for the agents, not your own: agents can read every message in it.
- Its IMAP server, such as `imap.fastmail.com`, and an **app password** made for Agents at
  the mail provider. Most providers need IMAP turned on first.

## Connect Email

On **Connectors**, choose **Connect… ▸ Email** on the Mac (**Connect Email…** on the
Remote and the web page). Give the IMAP server, the user (usually the address) and the app
password, then **Connect**. The host signs in once to check them, and keeps the password in
its own store: the Keychain on a Mac, `~/.agents-secrets` on Linux. The password never goes
back to a client or into a log.

A server name alone means IMAP over TLS on port 993. `imap://host` uses STARTTLS on port
143. A port can follow the name: `imap.example.com:1993`.

You can use variables in place of the connection: set `EMAIL_IMAP_URL`, `EMAIL_USER` and
`EMAIL_PASSWORD` for the server. With `EMAIL_PASSWORD` set, they go first.

## Add the page and the event

1. Add **Email** from the **Agents** marketplace in the catalogue, or by hand in the folder's
   `.agents/mcp.json`:

   ```json
   { "mcpServers": { "email": { "command": "email-mcp", "hosted": true } } }
   ```

2. In **Folder Settings ▸ Agent Configuration ▸ Connectors**, choose **Approve** on
   `email`. See [Add a connector by hand](add-a-connector-by-hand.md).

3. To keep the Mail page in the sidebar, pin it in the folder's `.agents/pins.json`:

   ```json
   { "pins": [ { "pinned_by": { "person": true }, "title": "Mail",
       "view": { "server": "email", "tool": "show_mail", "uri": "ui://email/mail" } } ] }
   ```

   Or pin the page from the app, as any other page.

## Answer sign-up codes

A folder that pushes to GitHub or GitLab lists the ready-made workflow **Answer a sign-up
code**, off. Turn it on in the folder's Workflows. Then, when mail comes from a sender on its
list (gitlab.com, github.com, DigitalOcean and AWS to start with), a new agent reads the code,
finds the session that waits for a code from that service, gives it the code with
`message_session`, and marks the mail read. It acts only on the senders on its list: to trust
another sender, add a trigger with its address as `from`.

## Wait for a mail in a session

An agent can wait for a mail itself, with `wait_for_event` on the mail server's event:

- event `email.received`
- where `{"from": "*@gitlab.com", "subject": "*code*"}`

Each argument is optional:

| Argument | What it does |
|----------|--------------|
| `from` | Only mail from a sender whose address matches, such as `*@gitlab.com`. `*` is any text, `?` one character; case does not matter. |
| `to` | Only mail to an address that matches. |
| `subject` | Only mail whose whole subject matches, such as `*verification code*`. |
| `folder` | The folder to watch. `INBOX` when left out. |

The server holds an IMAP IDLE connection on each folder that is watched (four at most), so a
mail is seen in about ten seconds and a quiet mailbox costs the mail server nothing. A server
without IDLE is asked once a minute.

## When it does not work

- **"No mailbox is connected":** connect Email, or set the three variables.
- **"The mail server refused the sign-in":** the app password is wrong or was taken back, or
  IMAP is off at the provider.
- **A message id stops working:** the message was moved, or the server renumbered its folder.
  List the folder again.

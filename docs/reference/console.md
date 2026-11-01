---
diataxis: reference
devices: [web]
description: The Console, the control plane's app for admins on the web page — its pages, what each shows and what an admin can do there.
---

# The Console

The Console is the control plane's app for admins (#1804). It is on the web page only. The
switcher at the top of the page moves between three apps: **Workspace** (the sidebar and the
chats), **Console** and **Reports**. The address is `#/console/<page>`.

Only an admin can open the Console. A member who opens it is told why. The Mac and the
Remote do not have a Console. They keep People and Groups in Settings, and the join
requests and cap notices come to them as cards.

## Pages

| Page | What it shows | What an admin can do |
|---|---|---|
| **Overview** | Each page of the Console, with one line on what it is for. The Requests card shows how many requests wait. | Open a page. |
| **People and Groups** | The people, their roles and their machines; the bots, in a section of their own; and the groups. These are the same sections as Settings ▸ People, Bots and Groups. | Invite a person, change a role, make a bot, make a group. |
| **Machines** | Every machine (`console/fleet`): its owner, its state, its version, whether it is out of date, how many agents run on it and when it last listed them. Filters: All, Offline, Out of Date. | Read only. |
| **Sign-In** | The built-in providers (Apple, Google, GitHub), and your organisation's own (`signIn/orgProviders/list`, #1002): each one's kind, issuer, client ID, who may join, the secret's fingerprint and the redirect URI to copy. Under each, its claimed domains with their TXT records, and its SCIM with the base URL and its tokens. | **Add Provider…** (Okta, Microsoft Entra ID, Google Workspace, Other OIDC), **Check**, **Edit…**, **Replace Secret…**, **Move Up**, **Move Down**, **Turn Off**, **Remove…**; **Claim Domain**, **Check**, **Send people here**, **Require this provider** (with a preview first), **Remove…**; **Turn On SCIM**, the match attribute, **Make Token** (shown once), **Revoke…**. See [Sign in with your organisation](../how-to/sign-in-with-your-organisation.md). |
| **Live Now** | Every agent that runs now on every machine (`console/live`, #2019): its runtime and workflow, whose machine it is, its state (working, waiting for its person, waiting on others), when it started and its cost so far. The most costly agent comes first. No title and nothing it said. | **Stop** ends one agent (`console/stopAgent`). **Stop All on This Machine…** asks first, then stops each agent on that machine. For an incident, **Stop All Agent Work** in Policy stops everything. |
| **Report Policy** | Totals Only, the leads of each group, and a budget a month for each group and for the organisation (`reports/policy`). | Change them and select **Save** (`reports/setPolicy`). |
| **Team Workflows** | Each bot (`console/teamWorkflows`): its group, its machines online, its spend today against its cap, the workflows it ran in the last 7 days, and the agents that run on its machines now. | **Stop** an agent that runs on a bot's machine (`bots/stopRun`). |
| **Catalogue** | **Who Uses What**: each MCP server and skill that machines have from a catalogue, at each version, on how many machines and whose (`governance/usage`, #2019). Each machine sends this list each hour. **Approved**: each approval, for a group or a person (`governance/approvals`). | **Take Back** an approval (`governance/revoke`). |
| **Requests** | Machines that ask to join, channel identities that ask to be linked (`links/requests`), each bot that stopped at its cap, and people who ask for an MCP server or skill (`governance/requests`). The count beside **Requests** includes them all. | Approve or refuse a join or a link. **Change Cap…** opens the bot's sheet. Approve an MCP server or skill for the person or for a group, or refuse it (`governance/decide`). |
| **Audit** | Who did what through the control plane. This is the same pane as Events ▸ Audit. | Choose whose entries to see, change how long entries are kept, and export them. |
| **Read API** | The tokens BI tools read the reports with (`readApi/list`, #2019): each one's name, who made it and when, and its last use; the URL to read; and the OTLP exporter, when agents-control's environment sets one. See [Reports](reports.md#reading-the-reports-from-another-tool). | **Make Token** (its value shown once), **Revoke**. |

## Report Policy

- **Totals Only:** when on, a group's leads see the spend and time of the group added up,
  with no person or machine named. When off, they see each person. An admin always sees
  each person.
- **Leads:** the people of a group who see its reports in Reports, beside their own.
- **Budgets:** an amount of US dollars for a calendar month, for each group and for the
  organisation. Reports ▸ Spend shows the spend of this month against it, with a forecast.
- **Edits not saved stay (#2072).** The page says "Not saved" until you select **Save**
  or **Revert**. A person who joins does not reset your edits. The edits stay when you open
  another page and come back. If you close the tab, the browser asks first.

## Asking for an MCP server or skill

A person asks in Settings ▸ Organisation Policy: the kind, the name, and why (`governance/request`). Each admin sees the request in Console ▸ Requests. An admin approves it for the person, or for a group. A group approval holds for each member: a member who asks later is approved at once, and members who already wait are approved with it.

An approval answers the request and keeps a record of it. The Policy's marketplaces still say what a machine may add.

The control plane keeps each of these with a limit: at most 10 waiting requests a person and 1,000 in all, a decided request for 30 days, 1,000 approvals, and 500 servers and skills from each machine. A machine's list goes when the machine leaves. A person's requests go when the person is removed.

## Audit, in the Console and in Events

The Audit pane is the same on the Mac, the Remote and the web page, in Events ▸ Audit and in
Console ▸ Audit (#2087). An admin can:

- **Choose whose entries to see:** Everyone, or one person (`audit/list` with `user`).
- **Change how long entries are kept:** 30, 90, 180 or 365 days.
- **Export the entries shown:** as CSV, a row per entry for a spreadsheet, or as JSON
  lines (`audit/export`). On the Mac and the Remote, **Export…** is a menu with the two.

A member sees only their own entries. [Events](events.md#audit-who-did-what) tells what
the audit keeps.

## See also

- [Reports](reports.md): Reports ▸ Spend, and the Reports pane on the Cost page.
- [Groups](groups.md): groups of people.
- [Channels](channels.md): channel identities and link requests.

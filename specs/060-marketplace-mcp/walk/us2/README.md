# 060 US2 walk notes

2026-09-27. Scratch root `/tmp/run-060`, personal home `/tmp/run-060-home`, fixture
registry on `127.0.0.1:8932`.

Socket, frame D's behaviour:

- Context7 added to the project is in `<work>/.agents/mcp.json` with `${CONTEXT7_API_KEY}` only, and the approval digest is stored. The value is in the scratch `secrets.env`.
- A server written into the file afterwards (`pulled`, and earlier `notes`) is listed first as waiting, `isNew`, and `mcp/approve` takes only the digest the list showed.
- `notes` names `NOTES_TOKEN`, which is not set, so the list says so. A session would omit it (`MCPProjectTests.aMissingSecretIsListedAndLeftOutOfTheSession`).
- Same-name precedence, project ahead of personal, is `MCPProjectTests.theProjectsServerBeatsThePersonsOfTheSameName`.

The project page, once the window became active and re-read the file:

- **MCP servers** sits under Skills. The line under the heading says the file is committed and names secrets rather than holding them. **Reveal mcp.json** and **Add server…** are on the heading.
- `pulled` is first: **waiting for your OK**, "New with the last pull. No agent is given it until you approve it.", the command, **Show entry** and **Approve**. No Remove.
- `context7` shows **registry** and `npx -y @upstash/context7-mcp@4.1.1`, with **Replace…** and **Remove…**.
- `notes` shows **NOTES_TOKEN not set** and "Agents here start without it until you set NOTES_TOKEN.", with **Set…**. No Remove.

Before that activation the section still said "No MCP servers in this project yet." It had loaded while the file was empty, and it refreshes when the app becomes active.

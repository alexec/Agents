---
diataxis: how-to
devices: [mac]
description: Choose which marketplaces Add Connector… and Add skill… search, turn the provided ones on or off, and add your own, such as your company's MCP registry.
---

# Choose marketplaces

**Add Connector…** and **Add skill…** each search one marketplace at a time, chosen in the
**Marketplace** menu at the top of the sheet. The sheet remembers the last one you used,
and its footer names the host the results come from.

## The ones the app provides

| Marketplace | Kind | What it is |
|---|---|---|
| **GitHub MCP Registry** | Connectors | Curated by GitHub, most starred first. The default, because it is the easiest to find things in. |
| **MCP Registry** | Connectors | The official open registry: everything published, in its own order. |
| **Agents** | Connectors | The connectors Agents makes: GitHub, Linear, GitLab and Email. A file that every host carries, read with no network. It lists all of them before you type. |
| **skills.sh** | Skills | Skills on GitHub, most installed first. The default for skills. |
| **Anthropic skills** | Skills | The `anthropics/skills` repository. It lists every skill before you type. |

Each can be turned off. None can be removed.

## Turn one on or off

1. Open **Add Connector…** or **Add skill…**.
2. In the **Marketplace** menu, choose **Manage Marketplaces…**.
3. Use the switch on its row. **‹ Back** returns to the search.

What you turn off is saved in `~/.agents/marketplaces.json` as `off`.

## Add your own

1. In **Manage Marketplaces…**, choose **Add Marketplace…**.
2. Give it a name and its address:
   - for connectors, the base URL of any server that answers the MCP Registry API
     (`/v0.1/servers`): a company's own registry, self-hosted or not. It must be `https`,
     except on `localhost`;
   - for skills, a GitHub repository (`owner/repo`) whose folders hold `SKILL.md` files, or
     a site that answers skills.sh's search.
   - for connectors, a file on this machine instead: choose **A file on this machine** and
     type its path, such as `~/team/connectors.json`. See [A marketplace that is a file](#a-marketplace-that-is-a-file).
3. If the registry needs a token, type a name for it, such as `ACME_MCP_TOKEN`, and the
   token. The value goes into `~/.agents-secrets/secrets.env` and is never shown again. The app
   sends it as `Authorization: Bearer …` to that address only.
4. Choose **Add**. It is in the menu at once, and saved in `~/.agents/marketplaces.json`.
   **Remove** takes it out again. The token's value stays in `secrets.env`.

A skills repository can be private: the app reads a private one through `gh`, so it works
when `gh` is signed in on this Mac with access to the repository, and says the repository
is unreachable otherwise. A public one is read over plain HTTPS and needs no `gh`.

## A folder's marketplaces

A folder can ship its own list in `.agents/marketplaces.json`, committed with it, in the
same shape:

```json
{
  "marketplaces": [
    { "name": "Acme", "format": "mcp-registry",
      "url": "https://mcp.acme.example", "token": "ACME_MCP_TOKEN" }
  ]
}
```

`format` is `mcp-registry`, `skills.sh`, `github-skills` or `file`. They are listed when the sheet
adds to that folder, marked **folder**, and they start **off**. A committed file could
otherwise send a token from your `secrets.env` to any address it names. Turn one on, and
that choice is saved as `on` in your own `~/.agents/marketplaces.json`, not in the folder.
Edit the folder's list in the file itself.

## A marketplace that is a file

A connector marketplace can be a JSON file, or a folder of them, in the MCP Registry's shape:
`{"servers": [{"server": {…}}]}`, or one `server.json` per file. A team can keep its own
connectors in its repository this way. The sheet lists every entry before you type, and the
words you type narrow the list.

```json
{
  "servers": [
    { "server": { "name": "io.github.acme/tickets", "title": "Tickets",
        "description": "Acme's tickets",
        "remotes": [{ "type": "streamable-http", "url": "https://mcp.acme.example/mcp" }] } }
  ]
}
```

A path is a full path, starts with `~/`, or is relative: to your home for your own list, and to
the folder for a folder's. Each entry runs as its `packages` or `remotes` say, as from
a registry. A file of your own or of a folder cannot name a command to run: only the Agents
marketplace, carried by the host, does that.

## If something is wrong

- **TOKEN not set** on a row: the token is named, but `secrets.env` has no value for it.
  Set it with the app's **Set…** on a connector that uses it, or in the file.
- **Every marketplace is off**: turn one on in **Manage Marketplaces…**.
- **marketplaces.json could not be read**: what it adds is left out, and the app writes
  nothing over it until it reads again.

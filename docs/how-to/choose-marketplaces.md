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
3. If the registry needs a token, type a name for it, such as `ACME_MCP_TOKEN`, and the
   token. The value goes into `~/.agents-secrets/secrets.env` and is never shown again. The app
   sends it as `Authorization: Bearer …` to that address only.
4. Choose **Add**. It is in the menu at once, and saved in `~/.agents/marketplaces.json`.
   **Remove** takes it out again. The token's value stays in `secrets.env`.

A skills repository can be private: the app reads a private one through `gh`, so it works
when `gh` is signed in on this Mac with access to the repository, and says the repository
is unreachable otherwise. A public one is read over plain HTTPS and needs no `gh`.

## A project's marketplaces

A project can ship its own list in `.agents/marketplaces.json`, committed with it, in the
same shape:

```json
{
  "marketplaces": [
    { "name": "Acme", "format": "mcp-registry",
      "url": "https://mcp.acme.example", "token": "ACME_MCP_TOKEN" }
  ]
}
```

`format` is `mcp-registry`, `skills.sh` or `github-skills`. They are listed when the sheet
adds to that project, marked **project**, and they start **off**. A committed file could
otherwise send a token from your `secrets.env` to any address it names. Turn one on, and
that choice is saved as `on` in your own `~/.agents/marketplaces.json`, not in the project.
Edit the project's list in the file itself.

## If something is wrong

- **TOKEN not set** on a row: the token is named, but `secrets.env` has no value for it.
  Set it with the app's **Set…** on a connector that uses it, or in the file.
- **Every marketplace is off**: turn one on in **Manage Marketplaces…**.
- **marketplaces.json could not be read**: what it adds is left out, and the app writes
  nothing over it until it reads again.

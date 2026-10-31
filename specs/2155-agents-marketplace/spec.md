# Spec: an Agents marketplace on disk (#2155)

Alex (2026-10-21): treat the connectors that Agents makes as just another connector, and have a
built-in (or on-disk) marketplace.

This changes part of #1428 ("Ours say Made by Agents and come first in the catalogue, in a group
of their own"). Alex can overrule each decision.

## What changes

1. **An "Agents" marketplace that the app provides**, after GitHub MCP Registry and MCP Registry
   in the menu. It can be turned off and cannot be removed, like the others.
2. **It is a file:** `Go/internal/agentsd/mcpcatalog/agents.json`, in the MCP Registry's list
   shape (`{"servers": [{"server": {…}, "_meta": {…}}]}`). Each host carries it inside `agentsd`
   and reads it with no network.
3. **Any marketplace can be a file:** the new format `file` in `marketplaces.json` (personal or
   project) names a JSON file, or a folder of them, in the same shape. A team can keep its own
   connectors in its repository.
4. **The connectors that Agents makes are rows like any other:** no group of their own, no
   badge. Their levels (Tools · Events · Views · Workflows · Tested) come from the file.
5. **Removed:** `mcp/made-by-agents`, its capability `mcp.made-by-agents/1`, and `madeByAgents`
   on `MCPCatalogResult` and `MCPServerHealth`, and the badge on all three clients.
6. **No change to `hosted: true`:** one copy per host (#488) is about how a connector runs.

## Decisions

- Decided: the built-in marketplace is a file in the repository, carried inside `agentsd`
  (`go:embed`), not copied to `~/.agents/marketplaces/agents.json`, because then every host
  (Mac and Linux) has the same list with no install step and nothing is written in the person's
  home. A person reads it in the repository.
- Decided: GitHub MCP Registry stays the default, and Agents is one item in the menu, because
  "just another connector" means it gets no first place.
- Decided: no badge; the row's publisher (**Agents**) and the marketplace say where it came from.
- Decided: a `file` marketplace lists every entry with no words typed, and filters by the words
  typed (name, title, description), because a file is short and has no search of its own.
- Decided: an entry's `_meta["dev.agentloops/connector"]` (`command`, `hosted`, `declares`,
  `tested`) is read only in the Agents marketplace. A person's or a project's file uses the
  registry shape (`packages`, `remotes`), because a committed file could otherwise make a
  connector that runs any command on the machine.
- Decided: a `file` marketplace's path is absolute, starts with `~/`, or is relative: to the
  home for a person's list, and to the project folder for a project's.
- Decided: the connector set-up of #1336 is unchanged: it still adds ours by itself when a
  project's forge can be read, because that is a set-up step, not a place in the catalogue.
- Decided: the workspace provider presets (the question from #2131) are not in the Agents
  marketplace in this change, because Add Provider has a set-up of its own (Connectors set-up ▸
  Where agents run). A later spec can list them.

## Wire

- `MarketplaceFormat` gets `file`.
- Removed: `mcp/made-by-agents`, `MCPCatalogResult.madeByAgents`, `MCPServerHealth.madeByAgents`.

## Each client

| | Mac | Remote | Web |
|---|---|---|---|
| Agents in the marketplace menu | Add Connector… | none (no catalogue there) | none (no catalogue there) |
| No group, no badge | Add Connector…, the connector rows | the connector rows | the connector rows |
| Add Marketplace… with **A file on this machine** | Marketplaces pane | none | none |

## Docs

- `docs/how-to/choose-marketplaces.md`: the Agents marketplace, and a file of your own.
- `docs/explanation/connector-levels.md`: no badge; the levels come from the file.
- `docs/reference/integrations.md`: where the connectors that Agents makes are listed.

## Verified

- Go: `TestOursAreListedAndAddedLikeAnyConnector` (the Agents marketplace, searched with no
  words and with some, then added hosted) and `TestAFileMarketplaceIsSearchedAndAdded` (a
  person's file, a remote previewed, a command in `_meta` not read).
- Walked on a scratch root: Add Connector… with GitHub MCP Registry first and no group, then the
  Agents marketplace's four rows (`specs/071-web-remote/walks/2155/`).

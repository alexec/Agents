# The product's final name (#4927)

**Status:** decided, 2026-11-12 (Alex chose Agent Loops). Epic #4925. No product code and no rename: this spec only.
**Clients:** none in the spike. A rename after it changes all three clients and the docs.

## What Alex asked for

The GitHub organisation needs a name, so the product needs its final name first. Today the
folder says "Agents", the App Store listing says "Loops: Agent Workflows" (#659), and the
hosted service is at agentloops.dev (`docs/explanation/direction.md`, principle 2).

Output: a short list of names, with Agent Loops on it. For each one: the GitHub
organisation, the .dev and .com domains, the App Store name, a trademark search (USPTO and
EUIPO), name clashes with other dev tools, and how it fits the look of #4926. Alex chooses.

## How it was checked (2026-11-12)

- **GitHub:** `gh api users/<name>` (an organisation and a user share one namespace).
- **Domains:** RDAP, `rdap.verisign.com` for .com and `pubapi.registry.google` for .dev.
  A 404 means not registered. Nothing was bought or reserved.
- **App Store:** the iTunes Search API, iOS and Mac. An app name must be unique in the
  store, so a name with no exact match can be used.
- **Trademarks:** web searches of the USPTO and EUIPO records and their mirrors (Justia,
  Markinton, the UK journal). It is not a legal clearance.
- **Dev-tool clashes:** web search, GitHub repositories, npm and PyPI.

## The short list

| | **Agent Loops** | Loops | Loopsheet | Inkloops |
|---|---|---|---|---|
| **GitHub `agentloops` / `loops` / …** | `agentloops` taken: a dormant user ("Loo", since 2022, one profile repo, last push 2023). **`agentloops-dev` and `agentloopshq` are free.** | `loops` taken; `getloops`, `loopsapp` taken | **`loopsheet` free** | **`inkloops` free** |
| **.dev** | **agentloops.dev: ours** (registered 2026-10-18, the live control plane) | loops.dev taken | **loopsheet.dev free** | **inkloops.dev free** |
| **.com** | agentloops.com taken: parked on a lander since 2026-04-23 (registrar Fushi Tarazu), so maybe for sale | taken (loops.com) | taken | taken |
| **App Store** | "Agent Loops": no exact app. Our record (Apple ID 6817621595) can take it by a listing rename | "Loops" taken (Pixelfed, RINGS.TV and others); that is why #659 chose "Loops: Agent Workflows" | no app | no app |
| **USPTO** | **AGENTLOOP**, Reg. 6689988, class 9, live, registered 2022-04-05, owned by an individual (goods not confirmed). One letter from ours. A second AGENTLOOP (97858016, AgentLoop Inc.) is dead | many live LOOP marks in class 9 (LOOP BV, 7963778, and others) | none found | none found |
| **EUIPO** | none found for AGENT LOOPS or AGENTLOOP | **IFS LOOPS**, EUIPO 019273080 (2025-11-07), class 9, AI agent software | none found | none found |
| **Dev-tool clashes** | "agent loop" is a common term (the loop every coding agent runs; many small repos named `agentloop(s)`; an "AgentLoop" platform in a vendor list). It describes the product, but it is hard to find in a search and weak as a mark | **IFS Loops** (agentic "digital workers", 2025), Loops (loops.so, email for SaaS) | none: "sheet" makes some people think of a spreadsheet | none: "ink" makes some people think of tattoo or drawing apps |
| **npm / PyPI** | npm free; PyPI `agentloops` taken | taken | free | free |
| **Fits the look (#4926)** | Good: two plain words in Atkinson Hyperlegible Next read cleanly; "Agent" says what it is; no picture, so the look carries it | Good in type; says less | Very good: a sheet of warm paper, charcoal ink: the name is the look | Very good: charcoal ink on paper |
| **Cost to change to it** | Least: the domain, the control plane, the store record and the public goal all say it already | Small: the store name says it | Large: new domain, new control-plane host, OAuth redirects, store listing, docs | The same as Loopsheet |

## Recommendation

**Agent Loops**, with the GitHub organisation **`agentloops-dev`** (it matches the domain)
and the domain **agentloops.dev**. It is free everywhere it must be, except the
`agentloops` GitHub name and the .com, and it costs the least: the domain, the control
plane and the store record have it already.

The risk is the live US mark **AGENTLOOP** (class 9, one letter different). Before 1.0 a
trademark lawyer's clearance, or a request to GitHub for the dormant `agentloops` name,
would lower it; both are Alex's to decide and neither is in this spike.

If Alex wants a name that is clear of every mark found, **Loopsheet** is the next one: its
GitHub name and .dev are free, no mark or app was found, and it fits the paper look best.
It costs a move of the domain and the control plane.

**Loops** alone is not recommended: IFS Loops is AI agent software in the EU register, and
the store name is taken.

## Open questions for Alex

1. Which name: Agent Loops, Loopsheet, Inkloops, or another?
2. Keep Agent Loops if it is free everywhere? (It is free except the `agentloops` GitHub
   name, the .com and the AGENTLOOP mark above.)
3. Must the domain stay agentloops.dev?
4. The GitHub organisation's name: `agentloops-dev`, `agentloopshq`, or ask GitHub for
   `agentloops`?

## Alex's answer

Alex, 2026-11-12, by form:

1. **The name is Agent Loops.**
2. **The GitHub organisation is `agentloops-dev`**, to match the domain.
3. **The domain stays agentloops.dev.**
4. **No trademark lawyer's clearance** for AGENTLOOP.

Next: making the `agentloops-dev` organisation is an outside account, so it is Alex's to do
(the epic's lead, #4925, puts it on Alex's list). The rename of the clients, the store
listing and the docs from "Agents" and "Loops: Agent Workflows" to "Agent Loops" is the
epic's later work, not this spike.

## Sources

- [IFS Loops launch](https://www.ifs.com/news/product/ifs-loops), [UK journal entry for IFS LOOPS with its EUIPO priority](https://www.ipo.gov.uk/t-tmj/tm-journals/2026-009/WO0000001901999.html)
- [AGENTLOOP 90604526 (Justia)](https://trademarks.justia.com/906/04/agentloop-90604526.html), [Markinton](https://markinton.com/trademark/agentloop-90604526)
- [AgentLoop in a vendor list](https://www.thesilab.com/vendor-directory/agentloop)

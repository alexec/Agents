---
diataxis: explanation
devices: [mac, iphone, ipad, web, server]
description: "The compliance pack for an organisation's IT and security team, to sign off Agents: where data goes, who gets it, how it is kept safe, and how long it is kept."
---

# Compliance pack

These pages are for an organisation's IT and security team, to decide whether they can
sign off Agents. Each page says what Agents does today. When something is not built yet,
the page says so and names its issue.

- [Data flow](data-flow.md): every part of Agents and every outside service, what data
  goes on each line between them, and whether it is encrypted in transit and at rest.
- [Sub-processors](sub-processors.md): each outside company that gets data, what it gets,
  and whether a self-hosted set-up can leave it out.
- [Security overview](security-overview.md): people, keys and sign-in, the one grant,
  sandboxes, where secrets live, logs, the coming organisation policy, and how to report
  a vulnerability.
- [Data and retention](data-and-retention.md): what each store keeps, how long, how
  large it can grow, and what is backed up and what is not.
- [Privacy](../../privacy.md) and [Terms](../../terms.md): the privacy policy and the
  terms of use.

## In short

- **Self-hosted first.** Your organisation runs its own control plane, on its own machine
  or in its own cloud account. The people who make Agents run no service in the path,
  unless you choose the hosted service.
- **Agents talks to no model itself.** Each runtime (Claude Code, Codex and the others)
  runs on a machine of yours and sends prompts and files to its own vendor. Agents does not
  see or copy that traffic.
- **Conversations stay on the machine that ran them.** The control plane's store holds who
  is paired and which machines there are, not conversations. A server's backups in the
  store are sealed.
- **Agents has no analytics, no tracking and no advertising** ([Privacy](../../privacy.md)).

## Not built yet

Data governance is roadmap step T8 (#1001, `specs/1001-data-governance/`). These parts are
built:

- **Redaction:** known token shapes are cut out of transcripts, `app-tools.jsonl` and
  `daemon.log` when they are written (see [Security overview](security-overview.md#logs)).
- **Erasure:** Delete also removes the runtime's own copy, and a restore never brings a
  deleted agent back (see [Data and retention](data-and-retention.md#erasure)).
- **Export and import:** an agent or a folder's agents as a `.tar.gz`, and brought back,
  archived, on another machine (see [Data and retention](data-and-retention.md#export-and-import)).

- **A tamper-evident audit:** a hash chain on the audit's entries, a seal for each day,
  `agents-control audit verify`, and syslog and HTTP sinks (see
  [Security overview](security-overview.md#who-did-what)).

The organisation policy (T5, #998) and org keys and model gateways (T6, #999) are built
too: see [Policy](../../reference/policy.md) and
[Org keys and gateways](../org-keys-and-gateways.md).

## Related

- [The control plane](../control-plane.md)
- [People and machines](../people-and-machines.md)
- [Architecture](../architecture.md)
- [Integrations](../../reference/integrations.md)

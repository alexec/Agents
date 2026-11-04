---
diataxis: explanation
description: What Agents is for, the principles for hosting, trust and data, the three ways to run it, how one organisation's data is kept apart from another's, and where each kind of data lives and is backed up.
devices: [mac, iphone, ipad, server]
---

# Direction

Agents is a software factory you can run yourself. Many coding agents work at once on
machines in the cloud or on your desk. You watch and answer them from a Mac, a phone or a
browser. The tools you work with every day, such as the tracker, code review, CI and mail,
show in the same place.

This page says where the product is going. It is the reference that milestones, specs and
issues agree with. When one of them disagrees with this page, change one of the two in the
same branch.

## Principles

Alex set these on 2026-11-03 (#3392, #3401, #3403). Every spec, plan and issue agrees with
them. A change that cannot agree says why, and which principle it leaves out.

1. **Nothing relies on the Mac.** The web page is a full client and has every feature. A
   Mac is a client, and a machine for its own local folders. It owns nothing else: no
   control plane that others need, and no relay.
2. **Three shapes, one product.** Hosted at agentloops.dev is the default way in.
   Self-hosted is for a customer who runs the control plane in their own cloud account or
   data centre. A person on their own is a hosted account with one person, or runs a
   control plane on their Mac as an option. Single-user use stays. Say "self-hosted", not
   "on-prem"; use "on-premises" only as a search word beside it.
3. **Everyone signs in. Nobody is anonymous.** A person signs in with Apple, Google or
   GitHub. A team organisation is expected to use single sign-on (OIDC, and SAML later)
   and SCIM. Single sign-on is free in every shape.
4. **Anyone can sign up, and gets an organisation of their own.** Each organisation is
   fully isolated from the others. The hosted service is free for now.
5. **Customers bring their own compute, repositories, AI and policies.** They set them up
   themselves. The operator of the hosted service cannot do it for them, or act for them.
6. **The control plane holds nothing it could misuse.** It routes messages and keeps a
   directory of people, clients and machines. It holds no customer AI key and no compute
   credential, and it cannot act as a client on a customer's machine. The customer's
   clients seal secrets to the customer's machines (#3401).
7. **Keep nothing that can stay on the customer's systems.** Keep the minimum, use
   pseudonymous ids instead of names where possible, and keep it for a short time. This
   keeps us in line with laws such as GDPR, and keeps a data leak small.
8. **Encrypt in transit and at rest, to the usual standard.** TLS 1.2 or later on every
   connection. The provider's encryption at rest, and envelope encryption with a KMS for
   what the service must keep. A customer's own key (BYOK) is the first enterprise option.
   End-to-end encryption is a product choice, for later.

## From nothing to working

The path a new person takes must be short, and must need only a browser. These are its steps, in order:

- Sign up on the web.
- Get a control plane of their own. They type no command and hold no key.
- Connect a machine provider, such as DigitalOcean, Codespaces, Coder or Docker.
- Pick a repository. A machine starts, clones it with a short-lived token and shows it as
  a folder.
- Work in the web page. Add the Mac app, the phone or a desktop machine later, by signing
  in on each.

Milestone 0.8 "Start on the web" builds this path. Each step that needs a CLI, a Mac or a
second screen today is a gap.

## Three ways to run it

The same programs make all three. Only who runs the control plane, and how many
organisations it serves, changes.

| Shape | Who runs the control plane | Organisations on it | For |
|---|---|---|---|
| **Hosted** (the default) | Us, at agentloops.dev | Many, one per account | Anyone who wants to start in a browser, alone or as a team |
| **Self-hosted** (on-premises, or in your own cloud account) | You, as a container on your own hosting | One | A team or a company that keeps everything in its own account |
| **Single user on a Mac** (an option) | Agents Host on your Mac | One, with one person | One developer who wants the control plane at home |

- In every shape, the agents run on the customer's own machines. "Hosted" means that we run
  the control plane, not the agents.
- The control plane is free in every shape. Its source is visible like the rest, all rights reserved.
- Hosted gives **one control plane per account**, each with its own store and key, on one
  service (`agents-hosted`, #1003).
- A feature is built for all three shapes, or it says which shape it leaves out and why.

## Tenancy: what belongs to what

Every record and every folder belongs to one organisation and one person:

```text
organisation           one control plane store prefix (hosted: one per account)
└── person             signed in with Google, Apple, GitHub or the organisation's single
    │                  sign-on; keyed by (issuer, subject)
    ├── client         a window, phone, iPad or browser; belongs to one person
    ├── machine        started by a machine provider, or registered; belongs to one person
    │                  (#1117)
    │   └── folder     a place to work on this machine
    │       └── worktree   one Git checkout of the folder, for one agent
    └── project        the record that folders join
```

A project can include folders on more than one machine. A folder joins a project by naming
the project's id in its `.agents/folder.json` (#2317). Each folder is in exactly one project.
The control plane adopts an id that it does not know, so a clone joins with nothing to set.

### Glossary

- **Machine:** a computer that runs agents, such as a Mac, a Linux box or a computer a
  provider starts.
- **Machine provider:** an MCP server that makes, starts and stops machines.
- **Folder:** a folder on one machine where agents work. A folder is not always a Git
  repository.
- **Worktree:** one Git checkout of a folder, for one agent.
- **Project:** the thing people work on. It joins folders across machines and has a
  tracker, code review, CI and reporting.

- **Organisation.** The control plane's records live under one store prefix,
  `<prefix>/v1/`. One organisation is one prefix. Nothing inside the prefix names the
  organisation, so records do not change when many prefixes share one service.
- **Person.** A person is in one organisation. Their user-scope settings and secrets go
  with them to each of their machines.
- **Machine.** A machine belongs to one person. The Unix account is the security boundary:
  two people never share one account or one `agentsd`. A team build server is one person's
  machine, or a bot's.
- **Folder.** A folder belongs to one machine. Its settings live in the folder's
  repository, in `.agents/`, when it has a repository.

### Isolation

- **Control plane data:** a store prefix for each organisation, and a control key for each
  organisation. A hosted organisation that asks for more gets a bucket and an encryption
  key of its own. No record is read across prefixes.
- **Machine data:** on the machine, in the owner's account. The control plane passes
  requests through, but does not keep transcripts, files or runtime sign-ins, except a
  server's backups, sealed, under its owner's prefix (#1815).
- **Credentials:** a secret lives in the person's account on their machines, or, for an
  organisation credential (such as a Slack app or an org model key), on the control plane,
  sealed to each machine's key. A secret is never written to the store in clear text.
  Today the control plane opens an organisation credential to seal it again for each
  machine. Principle 6 removes that: the customer's client seals it, and the control plane
  stores only what it cannot open (#3397).

## Where data lives

| Data | Where | System of record |
|---|---|---|
| People, clients, machines, codes, machine providers, policy | Control plane store: a folder or an S3 bucket | The store |
| Agents, transcripts, usage, time | The machine's data folder | The machine |
| Person's settings, skills, MCP servers | `~/.agents` on each machine | The machine, synced from the control plane later |
| Secrets | `~/.agents-secrets`, the Keychain | The machine |
| Folder settings, workflows, pins | `<repo>/.agents/` | Git |

The store is a key/object store with conditional writes. It is the database. A folder is
enough for one person, and a bucket is enough for many copies and for hosted. We add no
SQL database unless a measured need shows that the store cannot do the job.

## Availability and recovery

- **Control plane:** several copies share one bucket behind a load balancer. If one copy
  stops, its clients and machines go to another copy in seconds. Back up the bucket with
  the provider's versioning. Losing the control key means every client must pair again,
  and the machines' backups in the store no longer open, as they are sealed with a key
  made from it. Keep the key in a secret manager with its own backup.
- **Machines:** a machine is the only copy of its agents and transcripts. A cloud machine
  that is deleted takes its history with it. So a server backs up its agents and
  transcripts to the organisation's store, under its owner, sealed, and a new machine of
  the same person can restore them (#1815). A provider's delete backs the machine up
  first. A Mac backs up to a folder (#1810).
- **Release check:** the Review HADR workflow (#1557) checks availability, recovery and
  bounded data before each release.

## Bringing other tools in

Agents shows the tools a person works with, so that they do not leave the app:

- **Every integration is an MCP server** with tools, events and views (`ui://` pages, MCP
  Apps). There are no built-in adapters. Slack, email and chat are MCP servers too
  (#1223).
- **Every integration reaches five levels:** tools, events, views on all three clients,
  ready-made workflows, and proof on a real account
  ([integrations](../reference/integrations.md)).
- **An integration can belong to a project.** For example, a project's mailbox is a
  project-scope MCP server: its view shows the inbox, and its events start workflows.

## Reports

People who run an organisation must see what it used and did:

- **Usage, cost and time** for each person, project and machine, added up on the control
  plane from what machines send. Today each machine keeps its own figures, and only the
  clients add them up.
- **Who did what:** every action on a machine carries its person and client (T3, #996).
- **Policy and budgets** are set on the control plane, and machines enforce them (T5,
  #998).

## Money

Agents' source is visible, with all rights reserved (see `LICENSE`), and this page does not
depend on how it is paid for. The control plane stays free. If paid parts come later, they
come from running the hosted service, not from features taken out of the free app.

## Milestones

The milestones to 1.0 are in issue #1340. The order follows this page: the cloud way in
first (0.8), then teams (0.9), the docs, promotion and videos (0.10), enterprises (0.11) and
many organisations on one service (0.12).

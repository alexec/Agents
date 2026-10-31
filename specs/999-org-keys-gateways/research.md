# Research: Enterprise T6, org keys and model gateways

2026-10-21. What the code does today, and what each runtime takes. Each item: Decision, Rationale, Alternatives.

## R1. What exists to build on

| Piece | Where | What T6 takes from it |
|---|---|---|
| Accounts per runtime (#840, PR #2158, held) | `Go/internal/agentsd/accounts.go`, `AccountProfile.swift`, `AccountReach` in `daemon.schema.json` | `AccountReach` is a one-key object (`signIn`), made to gain cases. The picker, `Agent.accountID`, the allowance key `<runtime>:account:<id>`, and taking out the API-key variables that would answer first. |
| User secrets (#1760) | `Go/internal/controlplane/usersettings/`, `userscope.go`, `kms/kms.go` `SealFor` | The envelope (a data key per secret, wrapped by the keeper, bound to its store key), the delivery on channel 0 only to the person's machines, the hash dedup (`toldUsers`), `SecretsLeft` when a machine is removed. |
| HPKE sealing to a P-256 key | `Go/internal/controlplane/apns/seal.go` `Seal`/`Open` | The same suite to the machine's key. A machine's key is P-256 (`controllink.NewPrivateKey`), and `HostRecord.PublicKey` holds it. |
| The sign-in relay (056) | `Go/internal/agentsd/relay.go`, `runtimes.go` `launchFor`, `ToolPolicyCatalog.swift` | A loopback gate, a CA file the runtime trusts, a stand-in token; Codex through a `CODEX_HOME` of its own with `config.toml`. |
| The launch environment | `runtimes.go` `environment`, `allowed`, each runtime's `passed`; `RuntimeLaunch.swift` | Where the org account's variables go, after the runtime's own are taken out. |
| Policy (T5, PR #2164, held) | `specs/998-org-policy/` | `runtimes.<id>.reach` (FR-030), `requires`, `policyRefused`, `setBy`, Console ▸ Policy, the read-only Policy pane. |
| Provider secrets (#691) | `Go/internal/controlplane/providers/secrets.go` | Not used: a file in the control plane's home is not shared between copies. |

## R2. What each runtime takes

"Measure" means the build lane checks it on the real CLI (a fake provider on loopback is enough) before it builds that row. Names come from each vendor's docs as of 2026-10.

| Runtime | Kind | Variables or config the machine sets (secret values are always the stand-in) |
|---|---|---|
| Claude | Org key | `ANTHROPIC_BASE_URL=https://127.0.0.1:<port>`, `ANTHROPIC_AUTH_TOKEN=<stand-in>`, `NODE_EXTRA_CA_CERTS` |
| Claude | Bedrock | `CLAUDE_CODE_USE_BEDROCK=1`, `ANTHROPIC_BEDROCK_BASE_URL=<relay>`, `CLAUDE_CODE_SKIP_BEDROCK_AUTH=1`, `AWS_REGION`, `ANTHROPIC_MODEL` and the default-model variables from the model map |
| Claude | Vertex | `CLAUDE_CODE_USE_VERTEX=1`, `ANTHROPIC_VERTEX_BASE_URL=<relay>`, `CLAUDE_CODE_SKIP_VERTEX_AUTH=1`, `ANTHROPIC_VERTEX_PROJECT_ID`, `CLOUD_ML_REGION` |
| Claude | Azure | `CLAUDE_CODE_USE_FOUNDRY=1`, `ANTHROPIC_FOUNDRY_BASE_URL=<relay>`, `CLAUDE_CODE_SKIP_FOUNDRY_AUTH=1` (measure) |
| Claude | Base URL | as Org key; the relay forwards to the route's address |
| Codex | Org key, Azure, Base URL | `CODEX_HOME=<account folder>` (#840) with `config.toml`: `model_provider = "org"`, `[model_providers.org] base_url = "<relay>/v1"`, `env_key = "AGENTS_ORG_STAND_IN"`, `wire_api = "responses"`; `CODEX_CA_CERTIFICATE` |
| Gemini | Org key | `GEMINI_API_KEY=<stand-in>`, `GOOGLE_GEMINI_BASE_URL=<relay>` (measure) |
| Gemini | Vertex | `GOOGLE_GENAI_USE_VERTEXAI=true`, `GOOGLE_CLOUD_PROJECT`, `GOOGLE_CLOUD_LOCATION`, `GOOGLE_VERTEX_BASE_URL=<relay>`, `GOOGLE_API_KEY=<stand-in>` (measure) |
| OpenCode | every kind | `OPENCODE_CONFIG=<account folder>/opencode.json` with one provider (`anthropic`, `openai`, `amazon-bedrock`, `google-vertex`, `azure`, or an OpenAI-compatible one) whose `options.baseURL` is the relay and `options.apiKey` the stand-in (measure per provider) |
| Grok | Org key, Base URL | only if the CLI takes a base URL variable (measure). Otherwise not built. |
| Copilot, Cursor, Antigravity | none | sign-in only (spec D5) |

- **Decision**: one model relay, and each runtime pointed at it by its own variables or config file.
- **Rationale**: every runtime in the "Yes" rows already has a documented base-URL setting, so no runtime is patched.
- **Alternatives**: a key in the environment (refused: the agent can print it, spec D4); a system-wide proxy with TLS interception (refused: it needs a trusted root for the whole user, and sees all traffic).

## R3. The relay and each gateway's credential

| Kind | What the relay adds |
|---|---|
| Anthropic key | `x-api-key` (and takes out `authorization`) |
| OpenAI key, OpenAI-compatible gateway | `Authorization: Bearer <key>` |
| Gemini key | `x-goog-api-key` |
| Bedrock, API key | `Authorization: Bearer <Bedrock API key>` |
| Bedrock, role (Q1 A) | SigV4 with the short-lived AWS credential from the control plane |
| Vertex (Q1 A) | `Authorization: Bearer <OAuth token>` from the control plane |
| Azure, key | `api-key` |
| Azure, Entra app (Q1 A) | `Authorization: Bearer <Entra token>` from the control plane |
| Base URL | the route's header name and key, or none |

- **Decision**: the relay checks the stand-in in the header the runtime sends it in, takes that header out, adds the real one, and streams the answer. It writes no body anywhere.
- **Rationale**: the 056 relay works this way, and it is proven with Claude and Codex.
- **Alternatives**: one relay per route (more ports, no gain); the control plane as the relay (every token through the cloud, and no offline use).

## R4. Sealing to a machine

- **Decision**: HPKE (P-256, HKDF-SHA256, AES-256-GCM), as `apns.Seal`, with info `com.alexecollins.agents.orgroute.v2` and associated data `<route id>|<machine id>|<version>|<hex SHA-256 of the route's JSON without sealed>` (`controllink.OrgRouteAD`). The machine keeps the envelope, not the value.
- **Rationale**: a message seen by another copy, a log or a relay opens nowhere else; a file copied to another machine does not open there; an old envelope cannot replace a newer one.
- **Alternatives**: the value in the clear on channel 0 (as #1760 does today for user secrets; acceptable for a person's own secret, not for an organisation's); a key per route shared with every machine (one leaked machine opens all deliveries).

## R5. Counting tokens in the relay

| Answer shape | Where the usage is |
|---|---|
| Anthropic Messages (direct, Bedrock, Vertex, Foundry) | `message_start.message.usage` and `message_delta.usage` in the stream; `usage` in a whole answer |
| OpenAI Responses | `response.completed` → `response.usage` |
| OpenAI Chat Completions | the last chunk's `usage` (the relay adds `stream_options.include_usage` when absent) |
| Gemini | `usageMetadata` on the last chunk |

- **Decision**: the relay reads only these fields while it streams, and adds them to the turn by the stand-in (one per session).
- **Rationale**: the provider's own count is what the organisation pays for (spec D12).
- **Alternatives**: the runtime's own report only (Cursor-like runtimes report nothing; Claude's cost is a list price).

## R6. Where the routes show

- **Decision**: an org route is an `AccountProfile` with `source: organisation`, made by the machine from the delivery, not kept in `runtime-accounts.json`.
- **Rationale**: #840's picker, rows and allowance work unchanged; the person cannot remove what the organisation gave.
- **Alternatives**: a new list beside accounts (a second model, refused by the lane brief).

## R7. The Antigravity notice

`RuntimeLaunchCatalog.antigravity.signInNotice` holds Google's sentence and link, drawn by `RuntimeAccountView` on the Mac (and the same on Remote and web). The machine sends it with the runtime's sign-in methods.

- **Decision**: a policy value with three states (spec D10). The machine drops the notice for `accepted` and refuses Antigravity for `refuse`.
- **Rationale**: the notice exists so a person decides knowingly; in an organisation, the organisation decides.

## R8. Q1, short-lived tokens (open)

- **A, on the control plane**: needs the AWS STS, Google OAuth and Entra token calls in `agents-control` (gocloud.dev does not cover them; three small clients). Hosts hold tokens of an hour at most.
- **B, on the machine**: the same calls in `agentsd`; long-lived credentials on every machine, sealed.
- Plain keys are the same in A and B. A Bedrock API key and an Azure key need neither.
- **Recommendation**: A. The control plane is always on (it is hosted), and an organisation's security team asks first where long-lived credentials are.

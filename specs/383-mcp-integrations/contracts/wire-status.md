# Contract: trigger status on the wire

`WorkflowSummary` gains one optional field. Clients that don't know it ignore it (the
existing wire rule). `Web/src/protocol/generated.ts` is regenerated from the Swift source,
not edited.

```json
"mcpTriggers": [ {
  "name": "checks.failed",
  "server": "ci",
  "state": "active",
  "lastPolledAt": "2026-10-06T12:05:30Z",
  "lastEventAt":  "2026-10-06T11:40:02Z",
  "missedSince":  null,
  "failure": null
} ]
```

| `state` | Line under the trigger (all three clients) |
|---|---|
| `pending` | "Connecting to ci…" |
| `active` | "Checked 20 s ago · last event 25 min ago" (or "· no events yet") |
| `retrying` | "Can't reach ci since 12:01 · trying again in 40 s", in the warning colour |
| `stopped` | `failure.message`, in the error colour. `badArguments` is shown where file errors are shown. |
| `notThisHost` | "Runs on <host name>", using the names the page already shows for `hosts:` |

When `missedSince` is set, the line adds "Events may have been missed since 09:14" and a
**Clear** action. The action is a request (`workflows/mcpTrigger/clearMissed` with
`{workflowID, name}`), granted as any other change to a workflow is.

The status is pushed with the summary when it changes. It is never re-sent on a timer: "20 s
ago" is worked out on the client from `lastPolledAt`.

## Parity

| Client | Where |
|---|---|
| Mac | `Shared/UI/WorkflowStatus.swift`, under the trigger list on `App/Sources/Projects/WorkflowPage.swift` |
| Remote | The same `Shared/UI` view on `Remote/Sources/Projects/WorkflowPage.swift` |
| Web | `Web/src/views/WorkflowPage.tsx`, wording from `Web/src/model/workflows.ts` |

Row to add to `specs/071-web-remote/walks/parity.md`: "Workflow page: MCP trigger status ·
Mac ✓ · Remote ✓ · web ✓".

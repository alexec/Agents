# Quickstart: prove Auto works

On a scratch set-up (run-app skill), with the fake runtime or Claude and Codex signed in.

1. New session: the runtime chooser shows **Auto** first, "Picks Claude now".
2. Pills say **Ask**, **Default sandbox**, **Balanced**; no Permission requests pill.
3. Send. The header says **Auto · Claude**; `agents/get` shows `auto.runtimeID = claude` and the
   native mode and model.
4. Mark Claude out (`runtimes/markOut` in a test, or the allowances fixture). A new Auto session
   starts on Codex.
5. Settings ▸ Agent Runtimes ▸ Auto: exclude Codex. With Claude out, send: the prompt stays and
   the line names each runtime and why.
6. Mappings ▸ Permission mode: set Claude **Approve for me** to Bypass permissions; the cell says
   **yours**; a new session gets it; **Reset** returns **Accept edits**.
7. A workflow with `runtime: auto`, `model: smart`, `permission-mode: plan` runs on the first
   included runtime with its plan mode.
8. Repeat 1–3 on the Remote (simulator) and the web page: the same runtime is picked.

Go: `go test ./Go/internal/agentsd/ -run 'Auto|Level'`. SC-005: a test walks the shipped table
and fails on any auto-mapped cell with a higher access rank than its level.

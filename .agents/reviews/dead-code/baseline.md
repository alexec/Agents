# Dead-code review baseline

This file records confirmed false positives. Each entry names the analyzer, declaration
or path, and why the code is live. It is empty until the first complete scan confirms a
false positive. Do not add broad suppressions to make a scan quiet.

Tool pins for the first scan:

- Periphery 3.8.0
- `periphery-3.8.0.zip` SHA-256 `07d4e286e31dd79164df39097e0b59f533c94badbe18158464a455ea88a166d7`
- `golang.org/x/tools/cmd/deadcode` v0.49.0
- Knip 6.42.1

The Web Knip entry points are `src/main.tsx` and `src/sandbox/proxy.ts`, the two
JavaScript bundles declared in `Web/build.mjs`. Knip does not infer these API-based
esbuild entries, so `Web/knip.json` names them. The analyzer configuration has no ignores.

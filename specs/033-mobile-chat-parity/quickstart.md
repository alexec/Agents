# Quickstart: validating 033

All commands run from `/tmp/w-033`.

## 1. Build and test

```sh
xcodegen generate
cd Packages/AgentsKit && swift test          # the whole suite; compare with main if anything flakes
cd ../..
xcodebuild -scheme Agents -destination 'platform=macOS' -skipPackagePluginValidation build
xcodebuild -scheme Remote -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation build
```

Expected: the suite is green, including the new `ConsistencyTests` scan, `AgentsModel` pending
options, ceiling step and terminal output tests, and `files/mention` integration. Both schemes
build.

## 2. The Mac is unchanged

Use the run-app skill on a scratch root. Open a conversation with a tool run, a diff, a
queued prompt and a failure line, and screenshot it before and after the change. Expected: the
same rows, the same follow behaviour, and the same prompt bar.

## 3. The wire

On the scratch daemon's socket:

```json
{"jsonrpc":"2.0","id":1,"method":"files/mention","params":{"agentID":"<id>","term":"Transcr"}}
```

Expected: up to 30 entries under the agent's folder, each with `path` and `relativePath`.

## 4. The phone (Alex's walk, on a real iPhone and iPad)

1. Open a running agent. The reply follows as it streams, and the spinner is at the foot.
2. Scroll up. The view stays put, and "Something new" appears on the end button.
3. Tap a folded run: it unfolds. Tap a call: its detail shows raw input and any diff.
4. Change the mode and the model in the options row. Check the Mac shows both.
5. Attach a photo and dictate a sentence, then send while the agent works. Send shows the queue
   icon, and the prompt sits as "Waiting its turn". Remove it, and it goes on the Mac too.
6. Type `@Trans`: files from the Mac are offered. Choose one and send.
7. With a permission request up, the card floats above the prompt area, which stays beneath it.
8. Stop from the top bar. Archive returns to the project.
9. Type in one chat, open another, come back: the draft is there and only there.
10. iPad with a keyboard: Return sends, Option-Return adds a line, `/` plus arrows plus Tab picks
    a command, and Escape puts the list away.

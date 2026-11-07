---
name: seeded-keychain-items-prompt-the-app
description: "A Keychain item made with /usr/bin/security (even -A) raises a SecurityAgent prompt on Alex's screen when the app reads it; never seed items the app will read."
metadata:
  type: feedback
  modified: 2026-09-26T17:40:53.204Z
---

Seeding a credential for a walk with `security add-generic-password -A …` and then letting the scratch app read it (`SecItemCopyMatching` in `CredentialStore.secret(for:)`) hung the app's main thread in decrypt and raised a SecurityAgent dialog on Alex's screen (056 US2 walk, 2026-09-26). `-A` doesn't help: items made by `security` sit in Apple's partition, so any other app is prompted. Deleting such an item (`SecItemDelete`) did not prompt.

**Why:** a modal Keychain dialog lands in front of whatever Alex is doing, and the scratch app hangs until someone answers it.

**How to apply:** only seed items the app will delete or never read. To walk "a saved key is kept", check the item's presence with `security find-generic-password` (no `-w`), not through the app. If an app hangs in `SecItemCopyMatching`, kill it by pid and delete the item; the dialog closes with its client. The reverse direction is safe: the app reading Claude's own item *through* `/usr/bin/security` never prompts ([[claude-sign-in-relay-056]]).

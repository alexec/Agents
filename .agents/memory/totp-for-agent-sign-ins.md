---
name: totp-for-agent-sign-ins
description: Agent accounts use TOTP via scripts/totp.sh (otpauth); seeds in ~/.agents/secrets/<service>-totp
metadata:
  type: project
---

Accounts that agents sign in to use an authenticator app (TOTP), not a passkey on Alex's devices (#3908). The seed is in `~/.agents/secrets/<service>-totp` (mode 600); `scripts/totp.sh <service>` prints only the code, and `--save` writes a seed from stdin. The library is `otpauth` (MIT), pinned in `scripts/totp/package.json`: pyotp (last release 2023) and pquerna/otp (2024-12) failed the 12-month rule.

**Why:** a passkey on Alex's devices makes every sign-in wait for Alex (#3905, full autonomy).
**How to apply:** TOTP first, then SMS, then a call (#3906); a passkey-only site gets a software passkey on Chrome's virtual authenticator, as `scripts/okta-signin.mjs` does. See [[full-autonomy-goal]].

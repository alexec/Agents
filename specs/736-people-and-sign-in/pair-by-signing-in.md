# Amendment: pair by signing in (#2097)

Alex (2026-10-21): "I'd like to be able to pair a device via login."

This amends FR-009, FR-010 and FR-014 of [spec.md](spec.md). Alex can overrule each decision.

## What changes

1. **Sign-in comes first on the Mac and the Remote.** The Remote's pairing screen and the Mac's Connect sheet lead with the control plane's address and its **Sign in with …** buttons. The code goes behind **Use a Code Instead…**.
2. **A browser pairs by approval.** The web page asks for the email or GitHub login of a sign-in the person has. It shows a short code. Each signed-in client of that person shows a card: "**Chrome on Mac** wants to sign in as you." The person types the code that the browser shows, and approves. The browser pairs as that person. The request stops after 10 minutes.
3. **Codes stay.** A code from **Pair a Device** or **Add a Browser…** still pairs every client. It is the local owner's way, and nobody must have a cloud login (FR-002).

## Decisions

- Decided: the Mac and the Remote always lead with sign-in, and go to the code by themselves when the address has no provider on, because a client that is not paired cannot know whether a control plane has a provider on until it has its address.
- Decided: the browser says whom it is for by a typed email or GitHub login, not by a provider button, because a browser cannot do the Apple or Google sign-in that the apps do (FR-008) without an OIDC client that the operator registers (T9).
- Decided: the approver types the code that the browser shows, and does not only compare it, because anybody can type somebody else's email. A card that only asks for Approve can be approved by habit (approval fatigue). The code is on the browser's screen only, so only a person who sees that browser can approve it. The card that the person's clients get does not carry the code.
- Decided: the reply is the same when no person has that email or login: the browser shows a code and waits, and nothing is approved. So the page does not tell a stranger who has an account.
- Decided: the limits on approval requests are the ones that GitHub sign-ins have: 5 waiting for one person, 50 for the control plane, and the sign-in connections per address (`signInsPerSource`). A request ends after 10 minutes.
- Decided: **Add a Browser…** on the Mac stays, because it is the only way with no sign-in provider on.
- Decided: approval by a typed account works only where a sign-in provider (or an org provider) is on, the same gate as every `s:` connection, because the account typed is a sign-in's email or login.

## Wire

- `signIn/ask` (new), on an `s:` connection only: `SignInAsk {account, name}` → `Admitted`. The client's kind is `browser`. Before it answers, it sends `control/signInWaiting` with the code. It answers when the request is approved, and fails when it is denied, it runs out, or the connection closes.
- `SignInDecide` gets `code` (optional). `signIn/approve` of a request whose provider is `browser` needs the code, and fails with "That is not the code the browser shows." when it is wrong.
- `SignInRequest` with provider `browser`: `login` is the account typed, and `code` is empty.

## Each client

| | Mac | Remote | Web |
|---|---|---|---|
| Pair by signing in, first | Connect sheet | Pairing screen | **Sign in with your account** on the pairing page |
| Code | **Use a Code Instead…** | **Use a Code Instead…** | the code field stays below |
| Approve a browser | card with a code field | card with a code field | card with a code field |

## Requirements (replace FR-014)

- **FR-014**: A browser MUST pair by a code shown on a signed-in client, or by an approval on one of the person's signed-in clients with the code that the browser shows (#2097). Either way it becomes that person's client. Direct sign-in in the browser needs an OIDC client that the operator registers, and is T9.
- **FR-014a**: An approval for a browser MUST need the code that the browser shows, typed on the approving client. The card MUST NOT show that code.
- **FR-014b**: A request for an account that no person has MUST look the same to the browser as one for an account that a person has.

## Docs

- `docs/how-to/connect-a-window-or-phone.md`: sign-in first, the code behind **Use a Code Instead…**.
- `docs/how-to/sign-in-with-google-apple-or-github.md`: approving a browser.
- `docs/how-to/use-agents-in-a-browser.md`: pair by your account.

# Web Pairing Contract — `GET /ios-pair`

This is the contract the iOS app's seamless "Sign in with bumpyride.me" button targets. The iOS side is implemented in [`BumpyRide/WebPairingService.swift`](../BumpyRide/WebPairingService.swift); this document specifies what the [bumpyride-web](https://github.com/direwolfvm/bumpyride-web) side needs to add to support it.

The existing `/settings/tokens` page and `POST /api/sync/ride` endpoint are unaffected. The iOS app falls back to the existing paste-a-token UI if this endpoint isn't yet deployed.

## TL;DR

iOS opens `ASWebAuthenticationSession` at:

```
https://bumpyride.me/ios-pair?callback_scheme=bumpyride&state=<random>
```

Web app authenticates the user (signing them in first if needed), mints a fresh API token, and 302-redirects to:

```
bumpyride://pair?token=<plaintext>&state=<echoed-state>
```

`ASWebAuthenticationSession` captures that callback URL privately into the iOS app. Safari history never sees the token, and the custom scheme isn't registered system-wide (so no other app can intercept it).

## Endpoint

### `GET /ios-pair`

| Query param | Required | Notes |
|---|---|---|
| `callback_scheme` | yes | URL scheme to redirect to. Validate against an allow-list — today, only `bumpyride` is needed. |
| `state` | yes | Opaque CSRF token from the iOS client (a UUID today). Must be reflected back unchanged in the callback URL. |

### Behavior by auth state

**Unauthenticated** → 302 to `/login?next=<encoded-original-url>` so the user can sign in (or hit "create account" and sign up), then return here.

**Authenticated** →

1. Create a fresh API token. Suggested label: `"iOS device — <YYYY-MM-DD HH:MM UTC>"` or `"iOS — <user-agent hint>"`. The label is what the user sees in `/settings/tokens` later when they want to revoke a specific device.
2. 302-redirect to `<callback_scheme>://pair?token=<plaintext>&state=<state>`, where:
   - `callback_scheme` is the validated value from the request
   - `token` is the plaintext token (the same one-shot value `/settings/tokens` returns at creation; only the sha256 is stored at rest)
   - `state` is byte-for-byte identical to the request's `state`

### Error responses

| Condition | Response |
|---|---|
| `callback_scheme` missing or not in allow-list | 400 HTML error page ("This sign-in link isn't valid.") |
| `state` missing | 400 HTML error page |
| Server fault | 500 HTML error page |

The iOS app surfaces a generic "Couldn't sign in" if the session closes without a callback (e.g. user dismissed it from inside the auth session, or the web side 500s). For 400/500 it's fine to show your normal HTML error page — the user will see it in the system browser, then cancel out.

## Security notes

- **Plaintext token in the redirect URL is fine here.** `ASWebAuthenticationSession` captures the URL before it's handed to any other process; Safari history is not involved. The token is hashed at rest server-side (existing behavior).
- **`state` must round-trip exactly.** It defends against CSRF and request mix-ups. Any divergence and the iOS side throws `PairingError.stateMismatch` and refuses the token.
- **Allow-list the callback scheme.** Don't echo back arbitrary user-supplied schemes — a malicious link could otherwise hand the token to a different app that registered the same scheme externally. Today, allow only `bumpyride`. Adding test or staging schemes in the future is fine but they should be explicit allow-list entries.
- **Tokens issued this way are normal tokens.** They appear in `/settings/tokens` like any manually created one and can be revoked individually. Good for the "I lost my iPhone" use case.

## Suggested token label

Using the request timestamp or a short user-agent hint gives the user something useful in the revoke list:

```
iOS — paired 2026-05-13 14:32 UTC
```

The label isn't security-critical; it's purely UX for the revoke screen.

## Why `ASWebAuthenticationSession` over opening Safari directly

| | `ASWebAuthenticationSession` | Direct Safari |
|---|---|---|
| Token in browser history | no | yes |
| Other apps can claim the scheme | no | yes |
| Shared cookies with Safari (auto-recognize signed-in user) | yes (when not ephemeral) | yes |
| System-managed UI, dismissible by user | yes | only via app switching |
| Required entitlements | none | none |

So `ASWebAuthenticationSession` is strictly better here — same UX advantages, additional safety guarantees.

## Future: Universal Links

The custom scheme `bumpyride://pair` could be upgraded to a Universal Link (`https://bumpyride.me/ios-pair-callback`) backed by an `apple-app-site-association` file. That would make scheme hijacking impossible even outside of `ASWebAuthenticationSession`. It's not necessary while the entire flow lives inside an `ASWebAuthenticationSession`, but is the natural next-step hardening if we add other contexts (e.g. emailed pair links).

To support Universal Links, the web side would need to host:

```
https://bumpyride.me/.well-known/apple-app-site-association
```

with content like:

```json
{
  "applinks": {
    "details": [{
      "appIDs": ["LAKT4757H4.com.herbertindustries.BumpyRide"],
      "components": [{
        "/": "/ios-pair-callback"
      }]
    }]
  }
}
```

…and the iOS app would gain an `Associated Domains` entitlement listing `applinks:bumpyride.me`. Leave this for a follow-up.

## On the iOS side

- The seamless flow lives in [`BumpyRide/WebPairingService.swift`](../BumpyRide/WebPairingService.swift).
- Driven by the primary "Sign in with bumpyride.me" button in [`BumpyRide/WebAccountView.swift`](../BumpyRide/WebAccountView.swift).
- On success, the token is handed to `WebAccount.validateAndStore(token:)`, which hits `/api/me`, then writes to Keychain via `TokenStorage`.
- If this endpoint isn't yet live, the user will see the web app's 404 / error inside the auth session window. They can cancel out and fall back to the existing manual paste flow, which targets `/settings/tokens` and is unchanged.

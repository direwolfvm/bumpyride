# WeatherKit JWT token issuance failing — support summary

## The problem

Every WeatherKit request from our app fails at **token issuance**, server-side,
with:

```
Failed to generate jwt token for: com.apple.weatherkit.authservice with error:
Error Domain=WeatherDaemon.WDSJWTAuthenticatorServiceListener.Errors Code=2 "(null)"
```

This is `WeatherService.shared.weather(for:)` returning the above. The request
reaches Apple's WeatherKit auth service; Apple's service fails to mint the JWT.
It is **not** a client-side networking or coding error — the same code path
fires correctly, with a valid location, and only the token generation fails.

## Environment / identifiers

| | |
|---|---|
| App | BumpyRide (iOS) |
| Bundle ID | `com.herbertindustries.BumpyRide` (explicit — **not** a wildcard App ID) |
| Team ID | `LAKT4757H4` |
| Application identifier in profile | `LAKT4757H4.com.herbertindustries.BumpyRide` |
| Build | iOS, run on a **physical device** (real GPS fixes, EDT timezone) |
| Framework | WeatherKit (client framework, `WeatherService`) — not the REST API |

## What we have verified is correct

We have ruled out every common cause. Each of these was checked directly:

1. **Entitlement present in source.** The app's `.entitlements` file contains
   `com.apple.developer.weatherkit = true`.
2. **Entitlement present in the signed binary.** We decoded the embedded
   `embedded.mobileprovision` from the actual device build; it contains
   `com.apple.developer.weatherkit = true` bound to the explicit App ID
   `LAKT4757H4.com.herbertindustries.BumpyRide`.
3. **Explicit App ID, not wildcard.** WeatherKit requires an explicit App ID;
   ours is explicit.
4. **Signing chain is healthy.** HealthKit — provisioned through the *same*
   profile and team — works correctly on the same builds. Only WeatherKit's
   server-side token issuance fails. This isolates the problem to WeatherKit's
   auth service, not our signing.
5. **Account has WeatherKit.** The **WeatherKit usage dashboard is visible** on
   developer.apple.com for this account, confirming WeatherKit is enabled at the
   account level.
6. **WeatherKit capability enabled on the App ID** in
   Certificates, Identifiers & Profiles.
7. **Standard paid Apple Developer Program** membership (not a free/personal
   team, not Enterprise — both of which cannot use WeatherKit).
8. **Device clock** is set automatically / accurate (JWT validation is
   time-sensitive).

## What we have already tried

In roughly this order, with the error persisting after every step:

1. Waited well beyond Apple's documented WeatherKit enablement window
   (minutes-to-hours) — multiple days total.
2. Reviewed App Store Connect → Business → Agreements; **found and accepted
   pending agreements.** The last one showed Active shortly after acceptance.
3. Unchecked and re-checked the WeatherKit capability on the App ID in the
   developer portal (to force a re-registration), then saved.
4. Cleaned the Xcode build folder and rebuilt.
5. Deleted the stale cached provisioning profile so Xcode would regenerate a
   **fresh** one. Confirmed the new profile was created *after* the capability
   re-toggle and still carries `com.apple.developer.weatherkit = true` bound to
   the explicit App ID.
6. Rebuilt and reinstalled on the device with the fresh profile.
7. **Rebooted the device** to clear any cached auth failure in the local
   `weatherd` daemon, then tested with a fresh ride / fresh location fix.

After all of the above — fresh profile, reboot, agreements accepted, hours
elapsed — the request **still** returns
`WDSJWTAuthenticatorServiceListener.Errors Code=2 "(null)"`.

## Conclusion / what we need

Every client-side and account-side prerequisite is provably in place:

- entitlement in source **and** in the signed binary,
- explicit App ID with WeatherKit enabled,
- WeatherKit usage dashboard visible for the account,
- paid membership, agreements accepted,
- same signing chain successfully issues HealthKit,
- fresh provisioning profile + device reboot.

Despite this, **Apple's WeatherKit auth service refuses to issue a JWT for
App ID `LAKT4757H4.com.herbertindustries.BumpyRide` with error Code=2.** This
points to a server-side registration/state issue for this App ID (or this
account's WeatherKit service binding) on Apple's end, not anything in our
project.

We're requesting that Developer Support inspect the WeatherKit service
registration / JWT-authorization state for:

- **Team ID:** `LAKT4757H4`
- **App ID:** `LAKT4757H4.com.herbertindustries.BumpyRide`

and identify why the WeatherKit auth service is returning
`WDSJWTAuthenticatorServiceListener.Errors Code=2` for it.

## Exact log excerpt

```
Weather state: hasCache=false lastAttempt=never
Fetching weather near (36.0879, -75.8178)
Failed to generate jwt token for: com.apple.weatherkit.authservice with error:
  Error Domain=WeatherDaemon.WDSJWTAuthenticatorServiceListener.Errors Code=2 "(null)"
Encountered an error when fetching weather data subset;
  location=<+36.08787954,-75.81783507> +/- 12.27m (speed 0.55 mps / course 206.13)
  @ 6/14/26, 3:28:33 PM Eastern Daylight Time,
  error=WeatherDaemon.WDSJWTAuthenticatorServiceListener.Errors 2
  Error Domain=WeatherDaemon.WDSJWTAuthenticatorServiceListener.Errors Code=2 "(null)"
WeatherKit fetch failed:
  Error Domain=WeatherDaemon.WDSJWTAuthenticatorServiceListener.Errors Code=2 "(null)"
```

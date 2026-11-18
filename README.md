# Oktavi Staff for macOS

Native SwiftUI staff client for the Oktavi admin APIs. It implements the v1 scope in
`tmp/staff-app-agent-plan.md`, adapted from a browser PWA to macOS 14 or newer.

## Build and run

```sh
swift run OktaviStaff
```

Create an ad-hoc signed macOS application bundle:

```sh
sh scripts/package-app.sh
open "dist/Oktavi Staff.app"
```

The bundle uses the Oktavi brand icon from `Support/OktaviStaff.icns`.

Run the unit tests:

```sh
swift test
```

## Native security model

- The API key is validated with `GET /auth/me` and must have the `admin` role.
- Setup and unlock require the API domain each time. API keys must start with `okt_`;
  the server performs all further validation.
- PBKDF2-HMAC-SHA-256 with 600,000 iterations derives an AES-256-GCM key from the
  app password. The origin is authenticated as AAD.
- Only the encrypted envelope is persisted in the macOS Keychain. The plaintext key
  stays inside an actor-backed in-memory store while unlocked.
- Networking uses an ephemeral `URLSession` without cookies or a URL cache. Every API
  request sends `X-API-Key` and `Accept: application/json`.
- The app locks after ten minutes of inactivity or after being inactive for two minutes.
- EventKit synchronization maintains a dedicated `Oktavi Staff` calendar containing
  upcoming handovers, daily-rental pickups and returns, return appointments, and scheduled
  rental endings. It can run manually or whenever the app is unlocked.

## API prerequisite

This repository did not include the `auth_api`, `ressource_api`, existing admin frontend,
or Caddy sources referenced by the specification. The native client therefore assumes
that phase 0 API-key routes and middleware are already deployed. Those backend changes
cannot be implemented or tested from this repository alone.

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

- The API key is validated with `GET /auth/me`; authorization for staff operations is
  enforced by the protected `/api/v1/admin/*` endpoints.
- Setup and unlock require the API domain each time. API keys must start with `okt_`;
  the server performs all further validation.
- PBKDF2-HMAC-SHA-256 with 600,000 iterations derives an AES-256-GCM key from the
  app password. The origin is authenticated as AAD.
- Only the encrypted envelope is persisted in the macOS Keychain. The plaintext key
  stays inside an actor-backed in-memory store while unlocked.
- Networking uses an ephemeral `URLSession` without cookies or a URL cache. Every API
  request sends `X-API-Key` and `Accept: application/json`.
- The app locks after ten minutes of inactivity or after being inactive for two minutes.
- EventKit synchronization maintains a dedicated `Oktavi Staff` calendar. It contains handover and
  delivery slots only once the customer accepted them (title with customer and instrument, the delivery
  address as location, contact and assigned serial numbers in the notes), daily-rental pickups and returns,
  return appointments (pickup address as location) and scheduled rental endings. Slots that are pending,
  declined, replaced or already handed over are removed. It runs manually, on unlock, and – with automatic
  sync on and calendar access granted – after every dashboard refresh (every five minutes and after ⌘R),
  writing only events that changed.

## Working with the app

The sidebar follows the admin app's domains; every area is one click or shortcut away (menu **Gehe zu**,
⌘1–⌘8, back/forward with ⌘[ and ⌘]).

| Domain | Areas |
|---|---|
| Betrieb | Bestellungen (incl. handover and daily rental), Mieten, Rückgaben, Kündigungen |
| Finanzen | Kautionen, Rechnungen (issue, void, write off, record payment), Zahlungen (refunds), Zahlungsversuche, Währungen |
| Inventar & Logistik | Instrumententypen (photos, add instruments), Instrumente (status, master data, condition reports with photos), Lieferoptionen, Liefergebiete, Rückgabeoptionen, Mediathek |
| Kundenservice | Kunden (addresses, history), Benutzerkonten (roles, two-factor reset) |
| Rechtliches | Rechtstexte (versions, activate/deactivate) |

- **Das steht an** lists alerts by urgency; each opens the list filtered to exactly those records. The
  7-day agenda opens the order, return or rental directly.
- Each detail shows the lifecycle, the **next step** as the primary button, and secondary actions;
  destructive ones sit under "Weitere Aktionen". Problems link to where they are fixed, e.g. an order
  item without stock opens its instrument type, where "Instrumente hinzufügen" is the next step.
- ⌘R reloads everything, ⌘N creates a record in the current area, ⌘, opens the settings, ⇧⌘L locks.

Routes deliberately not used: customer-only routes (checkout, `/my/*`, slot answers, invoice payment,
OTP/2FA sign-in) and the legacy admin write routes that bypass the handover/return flow
(`/fulfillments/*` writes, `/orders/:id/assignments`, `/orders/:id/start-rental`,
`/admin/rental-returns/*`, `/rentals/:id/cancel`). `GET /orders/:id/fulfillments` is shown read-only.

## API prerequisite

This repository did not include the `auth_api`, `ressource_api`, existing admin frontend,
or Caddy sources referenced by the specification. The native client therefore assumes
that phase 0 API-key routes and middleware are already deployed. Those backend changes
cannot be implemented or tested from this repository alone.

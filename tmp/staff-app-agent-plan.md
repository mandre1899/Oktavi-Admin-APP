# Agent Plan: Oktavi Staff App (installable web app with an X-API-Key)

Status: draft, 2026-11-18. This plan covers what the app must do, how it calls the
Oktavi APIs, and which backend changes it needs first. Visual design is out of
scope. Wherever this file and the code disagree, the code wins:
`ressource_api/api/internal/router/init.go`, `auth_api/api/internal/router/router.go`
and the admin app in `frontend/oktavi-spa/src/admin/`. Note that
`in-depth-doc/routes.md` is partly out of date.

## 1. What the app is

The app is an installable web app (PWA) for the Oktavi team. It does the daily
work of the existing admin app (`/admin/`) on a phone or tablet, for both shops:

- **Monatsmiete** (monthly rentals), sold on `oktavi.de`
- **Tagesmiete** (daily rentals), sold on `rental.oktavi.de`

The admin app uses an email code, two-factor authentication and a session cookie.
This app works differently:

1. A team member pastes a personal **API key** once. Every request sends it as
   `X-API-Key`.
2. The key is encrypted on the device with an **app password** that the team
   member chooses. It is decrypted only in memory while the app is unlocked.
3. The app only calls the existing APIs. It contains **no business logic of its own**
   (no prices, VAT, fees or status changes worked out on the device). Every
   decision is made on the server. The app only decides which button to show,
   using the same rules the admin app uses (§ 7).

### Assumptions to confirm before building

| # | Assumption | Effect |
|---|---|---|
| A1 | ✅ **Confirmed (2026-11-18):** the app is for the team (staff with the `admin` role), not for customers. | Every route used is under `/api/v1/admin/*`, plus a few shared ones. |
| A2 | The app is served from the same origin as the main shop, at `{PUBLIC_BASE_URL}/app/`. | No CORS changes and no change to the same-origin check are needed (§ 4.4). |
| A3 | v1 covers the dashboard, operations (Betrieb) and deposits (Kautionen). Finance, inventory and the rest come later (§ 8). | Keeps v1 small. |
| A4 | Stack: Vue 3 + TypeScript + Vite, the same as `frontend/oktavi-spa`. | Types, `camelize`, labels and error translations can be copied or shared. |

## 2. Environments and domains

All API calls go to **one origin per environment**, the main shop's. Both shops
are served by the same API, so Tagesmiete bookings are also read through the main
origin (`/admin/orders?term=short_term`).

| Environment | App URL | API base (resource) | API base (auth) | Notes |
|---|---|---|---|---|
| Local | `https://localhost/app/` | `https://localhost/api/v1` | `https://localhost/auth` | Self-signed certificate. Vite dev proxy: same paths as `frontend/oktavi-spa/vite.config.ts`. |
| Staging | `https://dev.oktavi.de/app/` | `https://dev.oktavi.de/api/v1` | `https://dev.oktavi.de/auth` | The whole site is behind HTTP basic auth (`site-access-protected`, § 4.5). |
| Production | `https://oktavi.de/app/` | `https://oktavi.de/api/v1` | `https://oktavi.de/auth` | `www.oktavi.de` only redirects. Never call it. |

Rules:
- In the app, the API base is the **relative** path `/api/v1` and `/auth`, just as
  `shared/api/http.client.ts` does. No environment config is needed, because the app is
  served from the origin it calls.
- Never call `rental.oktavi.de`, `rental-dev.oktavi.de`, the Umami origin
  (`stats.*`), `/webhooks/*` or `/healthz`/`/readyz`. The health probes are internal and
  not exposed by Caddy.
- `/api/v1/media/:id` (public shop images) and `/api/v1/admin/media-files/:id/content`
  (private images, which need the key) are the only image sources.

## 3. How every request must look

| Rule | Detail |
|---|---|
| Auth header | `X-API-Key: <key>` on every `/api/v1/*` and `/auth/*` request except the public catalog reads. |
| No cookies | `fetch(..., { credentials: 'omit' })`. The key must be the only credential. The backend rejects a request that carries both (§ 4.2). |
| Content type | `Accept: application/json`. JSON bodies get `Content-Type: application/json`. Uploads send `FormData` with no Content-Type set by hand. |
| Field names | The API uses `snake_case`. Convert responses with `camelize()` (`src/admin/api/camelize.ts`) and write request bodies in snake_case. |
| IDs | UUIDs, except currency `code`, category `slug` and closed day `:day` (`YYYY-MM-DD`). |
| Money | Integers in minor units (`*_cents`) with `currency_code`. Format only for display (`de-DE`, `EUR`). Never add amounts up on the device. Use what the server sends: totals, `late_fee_cents`, `refundable_cents` and so on. |
| Time | Timestamps are RFC 3339. Booked days are `YYYY-MM-DD`, and Tagesmiete pickup and return times are `HH:MM`, both in **Europe/Berlin**. Compare days as strings, as the admin app does. |
| Lists | `limit` of at most 100, plus `offset`. The admin app always asks for `limit=100`. Lists are filtered with `status`, `term`, `state`, `type`, `direction`, `provider` and `search` (customers). |
| Empty answers | `204` has no body. `GET /admin/.../return` and similar routes can answer `204` for "none". |
| Idempotency | Card checkouts and payment attempts take an `Idempotency-Key` header. The admin routes in v1 don't need it, but the HTTP client must support it. |
| Errors | `{ "error": { "code", "message" } }`. Status codes: 400, 401, 403, 404, 409, 422, 503, 500. `message` is English, so show it through `translateApiError()` (copy `src/admin/api/errors.ts`). The same-origin check answers `403 {"message": ...}` without the envelope, so handle both shapes. |
| 401 | The key is invalid, expired or revoked. Lock the app and send the user to "Enter a new key". Don't retry. |
| 403 `forbidden` | The key's user is not, or no longer, an admin. Show "No permission". Don't log out. |
| 422 | A business rule refused the action. Show the translated message, then reload the record. |
| 503 | The auth service or a provider is unavailable. Show it and let the user retry. |
| Writes return the record | Every admin write returns the updated detail view (order, rental, return, deposit). Replace the screen's state with it. Don't build state on the device. |
| Caching | Never cache `/api/*` or `/auth/*` responses in the service worker or in storage. |

## 4. Backend changes needed first (phase 0)

Today **neither API accepts an API key**. Resource API auth is cookie only:
`ressource_api/api/internal/middleware/session.go` reads `oktavi_session` and checks
it against `GET /auth/me`. The agent must add the following. Each change needs
tests, following the existing `*_test.go` files.

### 4.1 Auth API: issuing and checking keys

- New table `api_keys`: `id`, `user_id`, `label`, `prefix` (first 8 characters,
  shown in lists), `key_digest` (SHA-256), `created_at`, `last_used_at`,
  `expires_at` (default 90 days), `revoked_at`.
  Keys are stored **only as digests**, like OTP codes and session tokens today.
- Key format: `okt_<env>_<32 random bytes, base64url>`, for example `okt_live_...` or
  `okt_test_...`. A key from one environment must not work in another.
- Routes:

| Method/path | Access | Body | Response |
|---|---|---|---|
| `POST /auth/me/api-keys` | Session + recent auth + two-factor passed + `admin` | `{label, expires_in_days?}` (at most 365) | `201 {id, label, prefix, key, expires_at}`. `key` is shown **only here**. |
| `GET /auth/me/api-keys` | Session | — | `[{id, label, prefix, created_at, last_used_at, expires_at, revoked_at}]` |
| `DELETE /auth/me/api-keys/:id` | Session | — | `204`, revokes the key. |
| `GET /auth/users/:id/api-keys` | Admin | — | Same list, for another user. |
| `DELETE /auth/users/:id/api-keys/:keyId` | Admin | — | `204` |

- Key checking: `sessionAuth` in auth_api accepts `X-API-Key` as an alternative to
  the cookie. `GET /auth/me` with a valid key returns the same body as for a session:
  `user_id`, `email`, `roles`, `authenticated_at` (= key `created_at`) and
  `session_expires_at` (= key `expires_at`). It also sets `last_used_at`, at most
  once a minute.
- **Roles:** a key carries its user's current roles at request time. It loses
  `admin` when the role is revoked, and it stops working when the account is
  suspended or deleted. Erasure (`/internal/v1/accounts/:user_id/anonymize`) must
  revoke all of the user's keys.
- Keys never pass "recent authentication". Routes that need it, such as
  `/auth/me/export` and `/api/v1/my/personal-data`, return `403` for a key. The app
  doesn't use them.
- Rate-limit failed key checks per IP, as OTP verification is rate-limited.
- Where to create a key: a "API-Schlüssel" section in the existing admin app (the profile
  or security page). It is created there and shown once.

### 4.2 Resource API: accepting the key

- In `middleware/session.go`, if `X-API-Key` is present, validate it through the same
  `GET /auth/me` call, sending the header instead of the cookie. Cache the result for
  `AUTH_SESSION_CACHE_TTL`, as for sessions.
- A request with **both** a session cookie and `X-API-Key` → `400
  {"error":{"code":"ambiguous_credentials"}}`.
- `AdminRouteProtection` stays the same: it reads the roles from the auth context.
- Never log `X-API-Key`. Add it to the existing request-log redaction.

### 4.3 Who is acting

Admin writes already record the acting user (`recorded_by` and similar) from the auth
context. A key resolves to its user, so audit fields keep working. Also log
`auth_method=api_key` and the key `prefix` in the request log.

### 4.4 Same origin, CORS, CSP

The app is served at `{PUBLIC_BASE_URL}/app/`, so its `Origin` matches and the existing
`sameOrigin` middleware passes. CORS doesn't need changing.
Changes needed:
- `frontend/Caddyfile`: a `handle /app /app/*` block with `try_files {path} /app/index.html`,
  the same as `/admin`, plus a page CSP without Stripe or Maps
  (`default-src 'self'; connect-src 'self'; img-src 'self' data: blob:; ...`).
- `frontend/oktavi-spa`: a third Vite entry `app/index.html` with history base `/app/`.
  Alternatively, build it as its own package in `frontend/` and copy it into the image.
- *If the app is ever hosted on another origin or wrapped natively (Capacitor):* add that
  origin to `CORS_ALLOWED_ORIGINS`, add `X-API-Key` to `Access-Control-Allow-Headers`
  (`middleware/cors.go`) in both APIs, and skip `sameOrigin` for requests that are
  authenticated by `X-API-Key` and carry no cookie.

### 4.5 Staging password wall

With `credentials: 'omit'` the browser also drops the staging basic-auth login (the same
thing Umami runs into, see `caddy/Caddyfile`). In `(site-access-protected)`, exclude
API requests that carry the key:
`@gated not path /webhooks/* /stats/api/send` plus
`not { path /api/* /auth/*; header X-API-Key * }`.
The API still rejects a missing or wrong key. The app shell at `/app/` stays behind the wall.

## 5. Key storage on the device (app password)

The key is encrypted and decrypted only on the device, with WebCrypto. The server never
sees the app password.

- **Setup:** paste the key, then call `GET /auth/me` with it. Accept the key only if the
  call returns `200`, `roles` contains `admin`, and the key prefix matches the environment.
  Then choose an app password (at least 10 characters, entered twice).
- **Encryption:** PBKDF2-SHA-256, 600,000 iterations, 16-byte random salt, gives the
  AES-256-GCM key (WebCrypto has no Argon2). The key is encrypted with a random 12-byte IV,
  with AAD = `"oktavi-staff-app:v1:" + origin`. IndexedDB stores
  `{v, salt, iv, ciphertext, prefix, email, created_at}`.
- **Never** store the key or the app password in `localStorage`, `sessionStorage`, the URL,
  logs, an error tracker or the service worker cache.
- **Unlock:** derive the AES key, decrypt, and keep the API key in a JS closure in memory,
  not in a reactive store that devtools can inspect.
- **Auto-lock:** after 10 minutes without input, and when the page has been hidden
  for more than 2 minutes. Locking wipes the key from memory and clears all loaded data.
- **Wrong password:** after 5 wrong tries in a row, wait 30 seconds before the next try.
  After 10, offer "Delete key on this device".
- **Server says 401:** delete the stored key and show "Key revoked or expired; enter a new key".
- **Menu actions:** "Change app password" (decrypt, then encrypt again) and "Remove key"
  (deletes the IndexedDB entry).
- A lost app password cannot be recovered. The user creates a new key in the admin app
  and enters it again.

## 6. What the app must be able to do (v1)

The screens mirror the admin app's views. The "reference" column names the file whose
behaviour must be copied.

### 6.1 Start and dashboard

| Screen | Calls | Rules / reference |
|---|---|---|
| Setup / unlock | `GET /auth/me` | § 5 |
| Dashboard ("Das steht an") | In parallel, and each may fail on its own (`Promise.allSettled`): `GET /admin/orders`, `GET /admin/deposits`, `GET /admin/returns`, `GET /admin/privacy-requests`, `GET /admin/contract-cancellations?status=open`, `GET /admin/system-status` | Alerts exactly as in `src/admin/modules/dashboard/admin.alerts.ts` (§ 7.1). Show a banner if a source failed. Pull-to-refresh. |

### 6.2 Orders (Bestellungen), monthly and daily

| Action | Call | Shown when |
|---|---|---|
| List | `GET /admin/orders?limit=100[&status=][&term=long_term\|short_term]` | Tabs from § 7.2, a filter by rental term, and a search over customer and order number on the device. |
| Detail | `GET /admin/orders/:id` | — |
| Approve | `POST /admin/orders/:id/approve` | `status == submitted`. Ask first (text in `OrderDetailView.vue`, `approveQuestion`). |
| Reject | `POST /admin/orders/:id/reject` | `status == submitted`. Ask first (`rejectQuestion`, which differs for a daily rental). |
| Cancel | `POST /admin/orders/:id/cancel` | `status ∈ {draft, approved, ready_for_fulfillment}`. Ask first (`cancelQuestion`). |
| Record early start | `PUT /admin/orders/:id/early-start` `{requested_at, note}` / `DELETE` | Monthly rental, before handover. |
| Tracking number | `PUT /admin/orders/:id/tracking-number` `{tracking_number}` (empty clears it) | `status ∈ {approved, ready_for_fulfillment, fulfilled}` |
| Out-of-stock warning | from the detail | An item with no active allocation and `free_instruments == 0`, while `status ∈ {submitted, approved, ready_for_fulfillment}`. |

### 6.3 Monthly handover (Übergaben)

Reference: `views/operations/HandoverDetailView.vue`. The steps are
assign instruments → agree on a slot → hand over.

| Action | Call | Shown when |
|---|---|---|
| Candidates | `GET /admin/orders/:id/allocation-candidates` → `{order_item_id: [instrument]}` | `editable` = `status ∈ {approved, ready_for_fulfillment}` |
| Assign | `POST /admin/orders/:id/allocations` `{order_item_id, instrument_id}` | editable, and the item still has units with no instrument |
| Unassign | `DELETE /admin/orders/:id/allocations/:allocationId` | editable, and the allocation has no rental yet |
| Propose slot | `POST /admin/orders/:id/handover/proposals` `{start_at, end_at, note?}` | editable, **and** the newest proposal is not `pending`, **and** (no `scheduled` slot **or** the user tapped "Replace slot"). Starts in the future, at most 24 h long. |
| Withdraw proposal | `DELETE /admin/orders/:id/handover/proposals/:proposalId` | the newest proposal is `pending` |
| Hand over | `POST /admin/orders/:id/handover/complete` `{at?}` (not in the future) | `status == ready_for_fulfillment` (all assigned and the slot accepted) |
| Handover failed | `POST /admin/orders/:id/handover/fail` `{reason}` | there is a fulfillment and it isn't completed |

The newest proposal is `handover.proposals[0]`. A declined proposal shows its
`decline_note`.

### 6.4 Daily rental (Tagesmiete) on the order detail

A daily rental has **no** assignment, slot, early start or tracking number: the
instrument and pickup time come from checkout. Reference: `OrderDetailView.vue`
and `components/operations/AdminDaily*.vue`, `AdminDepositSettlement.vue`.

| Action | Call | Rules |
|---|---|---|
| Hand over | `POST /admin/orders/:id/handover/complete` `{at?, rent_in_cash, deposit_in_cash}` | Only on one of the booked days (`rental_start_date..rental_end_date`), and only for `approved` that isn't handed over. If `rent_hold_lost`, take the rent in cash (`rent_in_cash: true`). |
| Return preview | `GET /admin/orders/:id/return-preview[?returned_at=]` | Show `late_days`, `late_fee_cents`, `card_on_file` and `next_booking_at_risk`. |
| Record return | `POST /admin/orders/:id/return` `{returned_at?, waive_note?, fee_in_cash}` | Late fee charged to the card on file, paid in cash, or waived with a reason. |
| No-show preview | `GET /admin/orders/:id/no-show-preview` | Only if `can_record` (from the pickup time on). Show `fee_cents` and `collection`. |
| Record no-show | `POST /admin/orders/:id/no-show` `{waive_note?}` | — |
| Settle deposit | `POST /admin/orders/:id/deposit/settle` `{retained_cents, note}` | Only if `deposit.settleable`. `0` releases it all. Keeping part needs a `note`, and the amount must be ≤ the hold. If the hold has lapsed, only "release" is possible. |

### 6.5 Rentals (Mieten)

Reference: `views/operations/RentalDetailView.vue`.

| Action | Call | Shown when |
|---|---|---|
| List | `GET /admin/rentals?state=active\|cancellation_scheduled\|ended` | — |
| Detail | `GET /admin/rentals/:id` | — |
| Cancel | `POST /admin/rentals/:id/cancellation` `{end_at}` (not in the past) | monthly, `state == active` |
| Withdraw cancellation | `DELETE /admin/rentals/:id/cancellation` | monthly, `state == cancellation_scheduled`, no `return_id` |
| End now (payment arrears, rental terms § 5.7) | `POST /admin/rentals/:id/end-now` | monthly, not `ended`, has a current period, and `effective_end_date` is empty or after today. The server checks the arrears (`422` otherwise). |
| Swap instrument | `GET .../swap-candidates`, `GET .../swap-delivery-options`, `POST /admin/rentals/:id/instrument` `{instrument_id, delivery_option_id, reason: size_change\|defect_replacement, previous_instrument_status: available\|maintenance}` | not `ended`, no `return_id`, has an instrument |
| Start return | `GET .../return-options`, `POST /admin/rentals/:id/return` `{return_option_id, pickup_address_id?, note?}` | no `return_id`. If there are no return options, show a hint to create one under Inventar & Logistik. |

### 6.6 Returns (Rückgaben)

Steps: appointment or label → received → inspection → completed. Reference:
`ReturnDetailView.vue`.

| Action | Call | Status before |
|---|---|---|
| List / detail | `GET /admin/returns[?status=]`, `GET /admin/returns/:id` | — |
| Appointment | `POST /admin/returns/:id/appointment` `{start_at, end_at, note?}` | `requested` (pickup or drop-off) |
| Label | `POST /admin/returns/:id/label` `{tracking_number}` (1–100 characters) | `requested`, `method == parcel` |
| Received | `POST /admin/returns/:id/receive` `{at?}` | `requested` or `scheduled` |
| Start inspection | `POST /admin/returns/:id/inspection` | `received` |
| Complete | `POST /admin/returns/:id/complete` `{instrument_status: available\|maintenance}` | `checkup` |

For a parcel return in `scheduled`, the label is "Label gesendet".

### 6.7 Cancellation inbox (Kündigungseingänge, § 312k BGB button)

| Action | Call |
|---|---|
| List | `GET /admin/contract-cancellations?status=open\|resolved` |
| Detail | `GET /admin/contract-cancellations/:id` |
| Enter on a rental | `POST /admin/contract-cancellations/:id/rentals/:rentalId/schedule` `{}` |
| Close otherwise | `POST /admin/contract-cancellations/:id/resolve` `{note}` (note required) |

### 6.8 Deposits (Kautionen)

| Action | Call | Shown when |
|---|---|---|
| List | `GET /admin/deposits[?status=pending]` | Oldest first, as the server sends them. |
| Confirm receipt | `POST /admin/deposits/:id/confirm` `{paid_at?, note?}` (`paid_at` ≤ now and not before the order) | `verification == manual` and `status ∈ {pending, submitted}`. Card deposits confirm themselves through the Stripe webhook, so there is no button for them. |

### 6.9 Customer lookup (read-only, handy at the counter)

`GET /admin/customers?search=&status=`, `GET /admin/customers/:id`,
`GET /admin/customers/:id/history`. Links go to the order and rental screens above.

### 6.10 App-wide behaviour

- Ask before every write that changes money or status. Reuse the German wording of the
  admin app.
- Disable the button while a request runs. Never send automatic retries for writes.
- After a write, show the returned record. If it fails with `422`, reload the detail.
- Offline: the shell loads and shows "Offline – keine Daten". Nothing is queued for later.
- Language: German. Use the label maps from `operations.labels.ts`, `finance.labels.ts`
  and so on.

## 7. Business rules to mirror (from the admin frontend)

### 7.1 Dashboard alerts (`admin.alerts.ts`)

`danger` alerts come first, then `warning`. Each is shown only if its count is above 0.
`today` is the Berlin date.

| Key | Tone | Condition |
|---|---|---|
| `system-down` | danger | `system-status`: `database.ok`, `auth_api.ok` or `worker.connected` is false |
| `automation-tasks` | danger | `automation.counts.requires_review + handed_to_admin` |
| `webhooks-failed` | danger | `webhooks.counts.failed` |
| `privacy-requests` | danger if any is overdue, else warning | status in `received, identity_verified, in_progress`. Overdue = `due_at` day < today. |
| `cancellations-open` | danger | cancellations with `status == open` |
| `handover-declined` | danger | order `approved` and `handover_proposal_status == declined` |
| `orders-submitted` | warning | order `submitted` |
| `daily-due` | warning | `short_term`, `approved`, `rental_start_date` ≤ tomorrow |
| `daily-hold-lost` | warning | `short_term`, `approved`, `rent_hold_lost` |
| `daily-overdue` | danger | `short_term`, `overdue_since` set |
| `handover-unscheduled` | warning | not `short_term`, `approved`, no `handover`, proposal not `declined` |
| `returns-requested` | warning | return `requested` with no appointment |
| `returns-arrived` | warning | return `received` or `checkup` |
| `deposits-open` | warning | `verification == manual` and status `pending` or `submitted` |

### 7.2 Order tabs (`OrderListView.vue`)

| Tab | Statuses |
|---|---|
| Neu | `submitted` |
| In Bearbeitung | `approved`, `ready_for_fulfillment`, `placed` |
| Übergeben | `fulfilled` |
| Abgeschlossen | `closed` |
| Abgelehnt/Storniert | `rejected`, `cancelled` |
| Alle | everything (drafts appear only with `status=draft`) |

### 7.3 Status lifecycles (the server enforces them; the app only shows them)

- **Order:** `draft → submitted → approved → ready_for_fulfillment → fulfilled → closed`.
  Side exits are `rejected` (from submitted) and `cancelled`. A daily rental is approved
  or rejected like a monthly one once its card step is done.
- **Handover proposal:** `pending → accepted | declined`. Fulfillment:
  `pending → scheduled → completed | failed`.
- **Rental:** `active → cancellation_scheduled → ended`.
- **Return:** `requested → scheduled → received → checkup → completed`.
- **Deposit or payment:** `pending → submitted → succeeded | failed | canceled | returned`.
- The minimum term (3 months) and notice period for monthly rentals apply to customers.
  Admins are not bound by them. Only the server works out end dates, so the app shows
  `effective_end_date` and `minimum_term_end_date` exactly as sent.

### 7.4 Things the app must never do

- Work out prices, VAT, fees, late days, refundable amounts or end dates.
- Change a status by sending a status field. Use only the action routes above.
- Show `iban` (only `iban_masked` exists) or log card details. Stripe client secrets
  never reach this app.

## 8. Later (not v1)

The same rules apply: copy the admin view's guards, use only its routes.
- Finance: `/admin/invoices*` (issue, void, write off, record cash or transfer payment),
  `/admin/payments*` (refunds), `/admin/sepa-*`.
- Inventory with the camera: `/instruments*`, condition reports
  (`POST /admin/media-files/condition-images` multipart up to 10 MiB, JPEG/PNG/WebP,
  then `POST /instruments/:id/condition-snapshots` with `media_ids`). Check points
  per category come from `condition-checklist.ts`.
- Daily-rental settings: `/admin/short-term/settings`, `/admin/short-term/closed-days/:day`.
- Push notifications for new alerts. This needs a new backend endpoint and is not designed yet.

## 9. Build order for the agent

1. **Phase 0, backend** (§ 4): auth_api keys, table, routes and tests → resource API
   middleware and tests → Caddy `/app/` route and the staging wall exception →
   admin-app section for creating keys.
2. App skeleton: Vite entry `/app/`, PWA manifest, a service worker that caches the shell only.
3. HTTP client (§ 3) with `X-API-Key`, `credentials: 'omit'`, error envelope + `translateApiError`,
   and 401/403 handling. Unit tests.
4. Key vault (§ 5). Unit tests: round trip, wrong password, tampered ciphertext, auto-lock.
5. Dashboard (§ 6.1) with `buildAdminAlerts` copied or shared, and its tests.
6. Orders, handovers, daily rental (§ 6.2–6.4).
7. Rentals, returns, cancellations, deposits, customer lookup (§ 6.5–6.9).
8. Playwright end-to-end test against the local stack with the development seed
   (`docs/testing/short-term-seed.md`):
   create key → set up app → approve order → assign → propose slot (accept as the customer
   in the shop) → hand over → daily rental return with a late fee → lock → revoke the key
   in the admin app → the app shows "key revoked".

## 10. Acceptance criteria

- With a revoked or expired key, every protected route answers `401` and the app locks itself.
- With a key whose user lost `admin`, `/admin/*` answers `403`.
- Key + cookie together → `400 ambiguous_credentials`.
- The key appears nowhere in plaintext: not in IndexedDB, localStorage, the service worker
  cache or the server logs (checked in tests).
- Each v1 button appears under exactly the conditions in § 6 and § 7. There is a unit test
  for every guard, mirroring the admin app's tests.
- The dashboard counts match the admin app's dashboard for the same data.
- No amount shown in the app is calculated on the device.

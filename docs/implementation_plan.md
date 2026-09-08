# GAROCA (GasRouteCalculator) — Implementation Plan

## Context

GAROCA is a new personal iOS app: the user photographs a gas station receipt, the system extracts the fuel purchase details (station, date, volume, price, total), stores them, and then shows a visualized route connecting fill-up locations over time along with aggregate stats (total spend, total distance, total time driven).

The repo is currently a bare skeleton (`main.py`, empty `src/garoca` package, `pyproject.toml` with no runtime deps, `uv.lock`) plus a README that left the architecture open. Those forks were resolved with the user:

- **iOS client**: native SwiftUI (thin client) talking to a Python backend over REST — not Kivy/BeeWare, since Apple's native camera/document-scanner/MapKit APIs and App Store approval are far smoother than a Python-compiled-to-iOS app, while all business logic still lives in Python.
- **Extraction**: a vision-capable LLM (Claude, via forced tool-use for structured JSON output) rather than traditional OCR+regex or a paid document-extraction API — receipts vary too much in layout for regex-based parsing to stay robust.
- **Routing/geocoding**: OpenRouteService (free tier) for geocoding station addresses and computing distance/duration between consecutive fill-ups.
- **Hosting**: a local FastAPI server on the user's own machine/NAS (reachable over LAN and, when away from home, via Tailscale), with DuckDB as an embedded single-file database on that same machine — no cloud deployment.

The app also needs to support **more than one person**, each with their own receipt history, and **more than one vehicle per person** (e.g. a car and a motorbike), so fuel spend/distance/time stay meaningful per vehicle rather than blended together. This started as a password-less profile picker, but the user decided real accounts are wanted instead:

- **Profiles represent people (with real login), and a profile can own multiple vehicles.** A receipt always belongs to exactly one vehicle, which belongs to exactly one profile.
- **Email + password login**, hashed server-side — not a bare picker. Registration collects name, email, password, color.
- **Session tokens**: login/register return an opaque token; the app stores it (Keychain) and sends it as a bearer header on every request; the backend resolves "who's asking" from that token rather than trusting a client-supplied profile id.
- **Data always stays scoped to the logged-in profile** (stats/route never blend across profiles, and are now enforced by the token, not just convention); within a profile, vehicle is an optional filter that defaults to combining that profile's own vehicles.

The user has already started `src/garoca/db/schema.sql` by hand with `profiles`, `vehicles`, `geocode_cache`, and `route_cache` tables (UUID primary keys, `email UNIQUE NOT NULL` on `profiles`); this plan's schema section reflects and extends that file (adding `password_hash` and a new `sessions` table) rather than replacing it. Everything else is still new code.

## Repo / package structure

Keep the existing `src/garoca` package and `pyproject.toml` (no restructuring). Organize by responsibility so extraction, routing, persistence, and the API are independently testable:

```text
main.py                                # dev entry point, launches uvicorn
.env.example / .env                    # config; .env gitignored
data/garoca.duckdb, data/receipts/     # gitignored: db file + stored receipt images

src/garoca/
  config.py                            # pydantic-settings Settings (API keys, host/port, model id, session TTL)
  db/
    connection.py                      # single long-lived duckdb.connect(), stored on app.state
    schema.sql                         # DDL (already started by hand) — extended with password_hash + sessions
    schema.py                          # loads/executes schema.sql on startup
    profiles_repo.py                   # CRUD on `profiles`, password verification helpers
    sessions_repo.py                   # create/lookup/delete session tokens
    vehicles_repo.py                   # CRUD on `vehicles`
    receipts_repo.py                   # CRUD/queries on `receipts`, always filtered by profile (+ optional vehicle)
    cache_repo.py                      # CRUD on `geocode_cache` / `route_cache`
  auth/
    security.py                        # hash_password()/verify_password() (bcrypt), generate_token()
  models/
    auth.py                            # RegisterRequest, LoginRequest, TokenResponse
    profile.py                         # ProfileOut, VehicleCreate/Out
    receipt.py                         # ReceiptCreate/Out/Update, status enum
    route.py                           # RoutePin, RouteSegment, RouteResponse, StatsResponse
  ocr/
    schema.py                          # ExtractedReceiptData (Pydantic, mirrors tool-use schema)
    prompts.py                         # tool-use prompt/schema text
    client.py                          # Anthropic SDK wrapper: extract(image_bytes, media_type)
    service.py                         # orchestration + failure handling
  routing/
    client.py                          # httpx wrapper: geocode(), directions() against ORS
    cache.py                           # geocode_or_cached(), route_or_cached()
    service.py                         # build_route(db, profile_id, vehicle_id=None) -> ordered segments + totals
  storage/
    images.py                          # save_upload/load/delete for receipt image files
  api/
    app.py                             # FastAPI factory + lifespan (opens/closes db connection)
    deps.py                            # get_db(), get_settings(), get_current_profile(token), get_ocr_service(), get_routing_service()
    routes/health.py, auth.py, me.py (vehicles/receipts/stats/route, all under /me)

tests/                                  # mirrors src/garoca/: db/, auth/, ocr/, routing/, api/
```

`main.py` becomes `uvicorn.run("garoca.api.app:app", host=..., port=..., reload=True)` for dev; production runs via `uv run uvicorn garoca.api.app:app --host 0.0.0.0 --port 8000`.

## DuckDB schema

Single file at `data/garoca.duckdb`, DDL in `db/schema.sql`, executed on startup. Only the FastAPI process opens it (one `duckdb.connect()` in the lifespan handler on `app.state.db`; requests use `app.state.db.cursor()`).

**`profiles`** — one row per person (extends what's already in `schema.sql`): `id UUID PRIMARY KEY DEFAULT uuid()`, `name TEXT NOT NULL`, `email TEXT UNIQUE NOT NULL`, `password_hash TEXT NOT NULL` (bcrypt hash — **new column to add**), `color TEXT NOT NULL`, `created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP`.

**`sessions`** — one row per active login (**new table**): `token TEXT PRIMARY KEY` (opaque random string from `secrets.token_urlsafe(32)`, generated in Python, not DB-generated), `profile_id UUID NOT NULL REFERENCES profiles(id)`, `created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP`, `expires_at TIMESTAMP NOT NULL` (e.g. now + 30 days, set at login time). `POST /auth/logout` deletes the row; an expired row is treated as invalid and lazily cleaned up.

**`vehicles`** — one row per vehicle, owned by a profile (already in `schema.sql`): `id UUID PRIMARY KEY DEFAULT uuid()`, `profile_id UUID NOT NULL REFERENCES profiles(id)`, `make TEXT NOT NULL`, `model TEXT NOT NULL`, `year INTEGER NOT NULL`, `created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP`.

**`receipts`** — one row per receipt, holding upload metadata and editable extracted fields (**not yet in `schema.sql` — needs adding**):
`id UUID PRIMARY KEY DEFAULT uuid()`, `profile_id UUID NOT NULL REFERENCES profiles(id)`, `vehicle_id UUID NOT NULL REFERENCES vehicles(id)`, `created_at`, `updated_at`, `image_path`, `status` (`uploaded|processing|needs_review|failed|confirmed`), `error_message`, `raw_llm_response JSON`, `station_name`, `station_address`, `latitude`, `longitude`, `receipt_date DATE`, `fuel_type`, `volume_liters`, `price_per_liter`, `total_amount`, `currency DEFAULT 'EUR'`, `field_confidence JSON`, `is_user_confirmed BOOLEAN DEFAULT false`, `confirmed_at`.

`profile_id` is denormalized onto `receipts` (in addition to the `vehicle_id` FK it's technically derivable through) so every list/stats/review query filters with a single `WHERE profile_id = ?` instead of joining through `vehicles` each time.

**`geocode_cache`** / **`route_cache`** — already in `schema.sql` as designed: `geocode_cache` keyed by `address_hash`, `route_cache` keyed by the rounded `(from_lat, from_lng, to_lat, to_lng)` coordinate pair. Both are shared across all profiles/vehicles — a station's coordinates and the distance between two points don't depend on who filled up there. (Minor note for when you touch that file next: `latitude`/`longitude` are currently `TEXT` in `geocode_cache` — worth changing to `DOUBLE` since they're used in numeric map/route math, and `route_cache.distance_meters`/`duration_seconds` are `INTEGER` where ORS can return fractional values, so `DOUBLE` is safer there too.)

No separate "trip" table: routes are derived at query time — `SELECT ... FROM receipts WHERE profile_id = ? AND (vehicle_id = ? OR ? IS NULL) AND is_user_confirmed AND latitude IS NOT NULL ORDER BY receipt_date`, then zip consecutive pairs through `route_or_cached`. Stats aggregate directly from `receipts` with the same filter; no materialized stats table needed at this scale.

## Authentication

- **Registration** (`POST /auth/register`): body `{name, email, password, color}` → `profiles_repo` checks email uniqueness, `auth/security.py.hash_password()` bcrypt-hashes the password (never store or log plaintext), inserts the profile, creates a session, and returns `{profile, token}` — auto-login after signup, no separate login step needed.
- **Login** (`POST /auth/login`): body `{email, password}` → look up by email, `verify_password()` against the stored hash, create a session row (`expires_at = now + settings.session_ttl_days`), return `{token}`.
- **Logout** (`POST /auth/logout`): requires the bearer token, deletes that `sessions` row.
- **Authenticating requests**: `api/deps.py` defines `get_current_profile(authorization: str = Header(...))` — extracts the bearer token, looks it up in `sessions`, 401s if missing/unknown/expired, otherwise returns the `profile_id`. Every `/me/...` route depends on it, so **profile scoping comes from the verified token, not from a client-supplied id** — this closes the gap the earlier profile-id-in-the-URL design had (anyone could edit the URL to read another profile's data); with real login, that's a genuine IDOR risk worth avoiding rather than a hypothetical one.
- **Password hashing**: use the `bcrypt` package directly (`bcrypt.hashpw` / `bcrypt.checkpw`) — simple, well-audited, no extra abstraction needed for a two-function job.
- **Cleartext-over-LAN caveat**: the backend is still plain HTTP (see reachability section) — logging in over the bare LAN IP sends the password in cleartext on the local Wi-Fi, whereas the Tailscale path is already WireGuard-encrypted end-to-end. Worth steering day-to-day use toward the Tailscale hostname for that reason; adding real TLS (e.g. a self-signed cert trusted via an ATS exception, or Tailscale's own HTTPS certs) is a reasonable later hardening step but not required to ship v1 on a home network.

## FastAPI endpoints

`/auth/*` are unauthenticated. Everything else lives under `/me/...` and resolves the active profile from the bearer token via `get_current_profile` — vehicle is an optional refinement (`?vehicle_id=`) on the read endpoints and a required field on receipt creation.

| Method & path | Purpose |
|---|---|
| `GET /health` | reachability check (phone "Test Connection" + manual curl), no auth |
| `POST /auth/register` | create profile (`name`, `email`, `password`, `color`) → `{profile, token}` |
| `POST /auth/login` | `{email, password}` → `{token}` |
| `POST /auth/logout` | invalidate the current session |
| `GET /me` | current profile info |
| `POST /me/vehicles` | add a vehicle (`make`, `model`, `year`) |
| `GET /me/vehicles` | list this profile's vehicles — powers the vehicle filter/switcher |
| `POST /me/receipts` | multipart upload (`image`, `vehicle_id`) → save image → **synchronous** OCR extraction → geocode → return `ReceiptOut` |
| `GET /me/receipts` | list (`limit`, `offset`, `status`, optional `vehicle_id`), ordered by date desc |
| `GET /me/receipts/{id}` / `.../image` | detail / stored image |
| `PATCH /me/receipts/{id}` | edit fields from review UI; re-geocode if address changed |
| `POST /me/receipts/{id}/confirm` | mark confirmed — **only confirmed receipts count toward stats/route** |
| `POST /me/receipts/{id}/retry-extraction` | re-run OCR for `status=failed` |
| `DELETE /me/receipts/{id}` | delete row + image |
| `GET /me/stats` | optional `vehicle_id`; total spend, liters, distance, duration, count, date range |
| `GET /me/route` | optional `vehicle_id`; pins + segments (with polyline geometry) for MapKit |

Every `vehicle_id` given to a `/me/...` route is checked to belong to the authenticated profile — 404 rather than leaking another profile's data. Upload+extraction stays synchronous for v1 (single user, few-second Claude call) — no job queue needed. `/docs` (Swagger UI) doubles as a manual test harness and as the spec the Swift networking layer is built against (note: exercising authenticated routes in Swagger UI needs the token pasted into its "Authorize" dialog after a `/auth/login` call).

## OCR / extraction module

- `ocr/schema.py`: `ExtractedReceiptData` Pydantic model mirrors the receipt fields plus `field_confidence: dict[str, float] | None`.
- `ocr/client.py`: Anthropic SDK, image as a base64 content block plus a **forced tool-use call** (`tool_choice={"type": "tool", "name": "extract_receipt"}`) whose input schema matches `ExtractedReceiptData` — parse `tool_use.input` via `ExtractedReceiptData.model_validate(...)` for free validation, avoiding free-text parsing.
- `ocr/service.py`: validates upload type, calls the client, sets `status=needs_review` on success or `status=failed` + `error_message` on `ValidationError`/API error.
- `field_confidence` is a **UI hint only** (highlight fields to double check) — it never gates anything server-side. The single correctness gate is the explicit `POST .../confirm` step, which keeps bad extractions from silently corrupting aggregates without needing a tuned confidence threshold.
- Anthropic model id lives in `config.py` so it can be bumped without code changes.

## Routing module

- `routing/client.py`: `httpx` wrapper around OpenRouteService — `geocode(address)` (`GET /geocode/search`) and `directions(points)` (`POST /v2/directions/driving-car/geojson`), raising a typed `RoutingError` on failure.
- `routing/cache.py`: `geocode_or_cached` / `route_or_cached`, normalizing/rounding then checking `geocode_cache`/`route_cache` before calling ORS. This absorbs nearly all traffic after the first few weeks since fill-ups repeat a small set of stations — well inside ORS's free-tier limits (~40 req/min, 2000/day) for personal use.
- `routing/service.py`: `build_route(db, profile_id, vehicle_id=None) -> RouteResponse`, the single function shared by `/me/route` (needs geometry) and `/me/stats` (needs only totals).
- Resilience: short retry/backoff (`tenacity`) around ORS calls; if a segment still fails, skip it and mark `incomplete: true` in the response rather than failing the whole endpoint — this is a casually-checked personal tool, it shouldn't break on a flaky free API.

## SwiftUI app (thin client)

- **LoginView / RegisterView** (launch screen when no valid stored token): email/password fields, "Log in" calling `POST /auth/login`; a "Create account" link/sheet with name/email/password/color calling `POST /auth/register`. Both store the returned token in the **iOS Keychain** (not `UserDefaults` — it's a credential) via a small `KeychainStore` helper. On launch, if a token is stored, call `GET /me` to confirm it's still valid before entering the app; on 401, clear it and fall back to the login screen. A "Log out" action (Settings tab) calls `POST /auth/logout` and clears the Keychain entry.
- **Vehicle context**: once logged in, a segmented control or menu (populated from `GET /me/vehicles`, with an "Add vehicle" action posting to `POST /me/vehicles`) sets the active vehicle filter — "All vehicles" (default, omits `vehicle_id`) or a specific one — applied to History, Map, and Stats. Capture always requires picking one concrete vehicle for the new receipt.
- `TabView` with Capture / History / Map / Stats tabs, plus a Settings screen for backend URL and logout:
  - **CaptureView**: `VNDocumentCameraViewController` (VisionKit) for edge-detected scans, `PhotosPicker` fallback; vehicle picker before/with upload.
  - **Upload → Review**: `POST /me/receipts` on capture → `ReceiptReviewView` form prefilled from extraction, low-confidence fields visually flagged, small MapKit pin preview from lat/lon; edits via `PATCH`, "Confirm" via `POST .../confirm`; failed extractions show "Retry".
  - **HistoryView**: `GET /me/receipts` (filtered by active vehicle), tap-through to reopen any receipt for edit.
  - **MapView**: SwiftUI `Map` (iOS 17+) with `Marker`/`Annotation` pins and `MapPolyline` per segment from `GET /me/route` (server flattens ORS GeoJSON into plain `[{lat, lon}]`, so Swift needs no GeoJSON parsing).
  - **StatsView**: stat cards bound to `GET /me/stats`, pull-to-refresh.
- **APIClient.swift**: URLSession + async/await, base URL stored in `UserDefaults` and editable in Settings (LAN IP or Tailscale hostname) with a "Test Connection" button hitting `/health`; the stored bearer token is attached as `Authorization: Bearer <token>` on every other request, with a shared 401 handler that routes back to the login screen.
- No extra Swift packages needed for v1 (SwiftUI/MapKit/VisionKit/Keychain Services are all in the iOS SDK).

## Local network / Tailscale reachability

- Bind uvicorn to `0.0.0.0` (not `127.0.0.1`) so the phone can reach it.
- Support both a static/DHCP-reserved LAN IP and a Tailscale MagicDNS hostname via the same Settings text field — Tailscale keeps one working URL both at home and away (requires the iPhone's Tailscale toggle on for MagicDNS off-LAN).
- CORS is irrelevant for a native client — skip it for v1.
- Since the backend is plain HTTP, add a scoped `NSAppTransportSecurity` exception in Info.plist for the specific LAN IP/Tailscale hostname. Now that real passwords and bearer tokens are sent (see the cleartext-over-LAN caveat under Authentication above), prefer the Tailscale hostname as the day-to-day path — it's WireGuard-encrypted in transit even though the HTTP payload inside is plaintext, unlike a bare local-Wi-Fi connection.
- Add a Windows Defender Firewall inbound rule for TCP 8000 from the local subnet/Tailscale interface (host machine is Windows per this repo).

## Dependencies

Runtime (`uv add`): `fastapi`, `uvicorn[standard]`, `duckdb`, `pydantic-settings`, `anthropic`, `httpx`, `python-multipart`, `pillow` (downscale/compress receipt images before sending to the vision API and before storing), `tenacity`, `bcrypt` (password hashing).

Dev (`uv add --group dev`): `pytest` (present), `pytest-asyncio`, `respx` (mock ORS in tests), `ruff` (optional). FastAPI's `TestClient` is httpx-based already, no separate test-client package needed.

Swift: none — SwiftUI/MapKit/VisionKit/Keychain Services are SDK-included.

## Build order

1. `db/schema.sql` finished (add `password_hash` to `profiles`, add `sessions` and `receipts` tables per above) + `connection.py`/`schema.py` to load it, `config.py`, FastAPI skeleton with `GET /health` — verify phone reaches `http://<lan-ip>:8000/health` over Wi-Fi.
2. Auth: `auth/security.py`, `sessions_repo.py`, `POST /auth/register`, `POST /auth/login`, `POST /auth/logout`, `GET /me`, and the `get_current_profile` dependency — test via Swagger UI: register two accounts, log in as each, confirm `GET /me` returns the right one and a bad/missing token 401s.
3. Vehicles: `vehicles_repo.py` and its endpoints — test that each account can add vehicles and only sees its own via `GET /me/vehicles`.
4. Full receipt pipeline scoped to the authenticated profile/vehicle: `storage/`, `ocr/`, receipts CRUD/review/confirm endpoints — test via Swagger UI with real receipt photos across both accounts, confirming one account's token never surfaces another's receipts.
5. `geocode_cache`/`route_cache`, `routing/` client/cache/service, `GET /me/stats` and `.../route` — confirm ≥3 distinct stations and validate summed distance/time, and that switching the `vehicle_id` filter changes the totals correctly.
6. SwiftUI login/register + capture → review flow (Xcode project, Keychain token storage, VisionKit, `APIClient`, Settings screen with ATS exception) against the running Python server over LAN.
7. SwiftUI vehicle switcher + `MapView` + `StatsView` — test over both LAN and Tailscale.
8. Polish: failure/retry UI, loading/empty states, session-expiry handling (401 → back to login), stretch items (avg consumption, PDF receipts, CSV export, password reset), fill out pytest coverage.

## Testing approach

- `db/`: temp DuckDB per test (`tmp_path`), verify schema + CRUD for `profiles`/`sessions`/`vehicles`/`receipts`, and that `route_cache` rounding makes near-identical coordinate lookups hit the same row.
- `auth/`: unit-test `hash_password`/`verify_password` round-trip and rejection of a wrong password; test that an expired `sessions` row is treated as invalid.
- `ocr/`: inject a fake client (no real Anthropic calls in tests) returning canned tool-use payloads; cover both valid extraction and malformed-response → `status=failed`.
- `routing/`: `respx`-stub ORS responses; assert a second call with the same rounded inputs is served from cache (HTTP call count stays 1).
- `api/`: FastAPI `TestClient` with dependency overrides (temp db, fake OCR/routing services) exercising: register two accounts, upload receipts under each token, and assert `GET /me/receipts`/`stats`/`route` for account A's token never includes account B's data; assert a missing/invalid/expired token 401s on every `/me/...` route; assert the `vehicle_id` filter narrows correctly within one account.
- Default fixtures fake all external APIs so `uv run pytest` never makes real paid calls; mark any deliberately-real-API test `@pytest.mark.integration` and skip by default.
- Manual end-to-end: run with `--host 0.0.0.0`, hit `/health` from the phone browser, run the SwiftUI app against that IP — register two accounts, add a vehicle to each, capture a real receipt into one, verify it appears only in that account's map/stats — then repeat with the Tailscale hostname while off home Wi-Fi to confirm the away-from-home path.

## Critical files to create first

- `src/garoca/db/schema.sql` (extend: `password_hash`, `sessions`, `receipts`)
- `src/garoca/db/schema.py`
- `src/garoca/auth/security.py`
- `src/garoca/api/app.py`
- `src/garoca/api/routes/auth.py`
- `src/garoca/ocr/service.py`
- `src/garoca/routing/service.py`
- `pyproject.toml` (add dependencies)

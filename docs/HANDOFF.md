# Sentri: hand-over for the next engineer or AI

Read this whole file before touching anything. It records what exists, what was verified, what was NOT verified,
the traps already found, and the exact next steps. The owner (Vic) is non-technical, works only from an Android phone,
and has limited AI credit, so be accurate, keep replies short and plain, and never ask him to paste secrets in chat.

## 0. Rules that prevent most mistakes
1. Nothing can be compiled or run for the Flutter app in the sandbox used so far. GitHub Actions is the only compiler.
   Treat every Dart edit as unverified until a CI run is green. Read errors from the run page (section 3).
2. Never put a secret (bot token, API keys, DATA_KEY...) in the repo, in chat, or in logs.
3. Never change `verified` in `mobile/assets/directory/police_directory.json` or the `verified_at` logic in the backend.
   Those control whether the SERVER may alert a police command. Only the on-screen wording was changed.
4. All SQL must use bound parameters ($1, $2...). `backend/test/sql-safety.test.ts` fails if SQL is built from text.
5. Every user-supplied value goes through a zod schema. Free-text rules already exist (see `modules/auth/routes.ts`).
6. A fake class that `implements` a Dart class must override EVERY member, including ones with default bodies.
   When you add a member to `SentriApi` or `LocationSource`, update the fakes in `mobile/test/helpers.dart`.
7. A Dart function type with a nullable optional parameter is NOT a subtype of one with a non-null optional parameter.
   `I18n.t` is `String t(String key, [Map<String, String> args = const {}])`; match it exactly when passing it around.
8. The app's theme makes every `FilledButton` full width (`Size.fromHeight(52)`). Inside a `Row`/`ListTile` give it
   `FilledButton.styleFrom(minimumSize: Size(96, 44))` or the neighbouring text collapses to one letter per line.
9. Keep all five language files (`mobile/assets/i18n/{en,ha,ig,pcm,yo}.json`) in step: same keys, same `{placeholders}`.
   `mobile/test/units_test.dart` enforces it. Hausa/Igbo/Yoruba/Pidgin text was written by an AI: have native speakers review it.

## 1. The product
Sentri is a personal-safety app for all Nigerians. One hidden action (shake, volume button, power button, floating
button) sends an SOS with live location to 3 to 5 trusted contacts INSIDE the app (inbox + push), never by SMS to
contacts. It also offers live location sharing, a police directory with the nearest command and one-tap calls, 112,
a cancel PIN and a duress PIN, five languages (English, Hausa, Igbo, Pidgin, Yoruba), and low-battery alerts.
Sign-up is by phone number; the one-time code comes through a Telegram bot (free), not SMS.

## 2. Repository: github.com/Victor1000000/Sentri- (branch main)
- `backend/` Node 22 + TypeScript + Fastify + zod. `src/modules/*` (auth, sos, share, inbox, dispatch, geo, admin,
  telegram, notify...). Postgres (PostGIS) + Redis (BullMQ) in real mode; in-memory stores for tests/dev.
  Tests: vitest. `npx tsc --noEmit` and `npx vitest run --exclude test/pg.integration.test.ts` must pass.
  Real-database tests: `TEST_DATABASE_URL=postgres://user:pw@localhost:5432/sentri_test npx vitest run test/pg.integration.test.ts`
  (needs Postgres 16 + PostGIS and the database name must contain "test").
- `mobile/` Flutter (Android only). `lib/core/net/api.dart` (HTTP client), `lib/features/*`, `lib/services.dart` (wiring),
  `lib/app.dart` (shell). Android scaffolding is generated in CI by `flutter create` (see workflow), only
  `mobile/android/app/src/main` is kept in git.
- `.github/workflows/sentri-apk.yml` builds the APK (release, falls back to debug). `apply-patch.yml` applies a patch file
  and pushes. `keep-awake.yml` pings the server every 5 minutes (needs repo secret API_BASE_URL).
- `Dockerfile.backend`, `render.yaml` (free test server, memory store), `render.live.yaml` (permanent server, see 8.3).
- `docs/` older design/security notes. This file.

## 3. How changes reach GitHub (important, unusual)
Nobody working on this has push access (the GitHub connector failed to sign in, no token). The only route:
1. Produce ONE patch file named exactly `sentri-telegram-signup.patch` (the name is hard-coded in `apply-patch.yml`;
   it is a historical name, the content can be anything). Create it with `git diff <remote main> HEAD`, excluding anything
   under `.github/workflows/` (the workflow token cannot change workflow files).
2. Vic uploads it to the repo's top level (github.com > Add file > Upload files; same name overwrites).
3. Vic runs Actions > "Apply Telegram sign-up patch" > Run workflow (he finds the button on
   `github.com/Victor1000000/Sentri-/actions/workflows/apply-patch.yml`, mobile layout can hide it: use "Desktop site").
   It applies the patch, runs `tsc` and the backend tests, pushes to main only if they pass, deletes the patch file,
   and starts the APK build.
4. Changes to files under `.github/workflows/` must be uploaded by Vic by hand into that folder (rename `.yml.txt` to `.yml`
   in GitHub's editor if his phone will not offer a `.yml`).
Always dry-run first: clone the repo fresh, `git apply --check`, `git apply`, then run the backend tests.

Reading a CI result without logging in (works; logs themselves need a login, annotations do not):
- list runs: `curl -sL https://github.com/Victor1000000/Sentri-/actions` and regex `"name":"Build Sentri APK","runNumber":N,"id":"(\d+)"`
- run page: `curl -sL https://github.com/Victor1000000/Sentri-/actions/runs/<id>`; strip tags; read "Status" and the
  annotations. The APK workflow prints build/test/analyzer errors as annotations ("build.log matches" etc.).
- The GitHub REST API is rate-limited from the sandbox; the artifact download link needs a login (Vic downloads it from the
  Summary page of the run, bottom, "Artifacts", `sentri-apk`).
Each CI build is signed with a fresh debug key, so Vic must UNINSTALL the old app before installing a new APK.

## 4. Current live state
- Remote main = commit `50d0773` (Telegram sign-up code). THE PATCH IN THIS HAND-OVER HAS NOT BEEN APPLIED YET.
- APK builds are green. The Telegram sign-up works end to end on the test server (Vic confirmed codes arrive).
- Render: free web service `sentri-api` from `render.yaml` (Frankfurt). Memory store: it forgets everything on every
  restart or after 15 idle minutes. Bot `@TheRealSentri_Bot`; token/username are Render env vars (never seen by the AI).
- GitHub repo secret `API_BASE_URL` = the Render address (no trailing slash). No secret means the APK points at a dead
  placeholder and sign-up fails with "Something went wrong".
- Paystack: Vic only just signed up, not verified. No billing code exists yet.

## 5. What this patch contains
Mobile
- `features/onboarding/permissions_panel.dart`: fixed the "one letter per line" glitch (see rule 8). Also used by trigger settings.
- `features/police/police_screen.dart` + `assets/i18n/*` (`police.note`, `police.approx`, `police.listed`): confident wording,
  badge "Official NPF line", removed the "reported ... not yet confirmed" captions, commissioner line only when a name exists.
- `assets/directory/police_directory.json`: Lagos now leads with the Lagos Command's own control-room numbers
  (08063299264, 08065154338, 09129229576, from lagos.npf.gov.ng), then the older NPF lines, and the text line
  "767 or 112 (toll-free)" LAST because the SOS card shows the first 3 lines as one-tap call buttons (must be dialable).
- `core/net/api.dart`: `HttpSentriApi` rewritten for reliability. Ordinary calls are "patient" (20 s timeout; on a timeout or a
  502/503/504 it polls `/healthz` up to 70 s for a sleeping server, then retries once). Emergency calls (`startSos`,
  `sendLocation`, `submitPin`, `lowBattery`, `inboxItem`, `respondToAlert`, `updateShare`, `reverseGeocode`) stay fast
  (8 s, no waiting). No connection at all fails immediately. `waking` notifier drives a banner. `prewarm()` at start.
  If a refresh is REJECTED (400/401/403/404) on a patient call the session is cleared and `onSessionExpired` fires; if the
  refresh merely could not be made (offline/5xx) nothing is signed out. Emergency calls never sign anyone out.
- `onboarding_controller.dart` `sessionExpired()`, `services.dart` (wires it, prewarm, `waking`), `app.dart` (banner,
  `DevicePlaceLookup`), `core/widgets/waking_banner.dart`, strings `net.waking`, `auth.session_ended`.
- Location: `LocationSource.preciseFix()` (GPS settles, best reading within 20 s or <=15 m), `features/location/place_lookup.dart`
  (device reverse-geocoding via the `geocoding` package, pure `placeFromPlacemarks`), `features/map/map_screen.dart` (accuracy
  chip, hint + buttons to location/app settings when worse than 100 m, landmark, place via device then server).
  Root cause of "Place name not available": the backend `GEOCODER` defaults to `none` so `/v1/geo/reverse` returns 404.
  Root cause of poor precision: Wi-Fi/tower fixes (+-300-400 m) and/or Precise location permission off. 100% precision is
  physically impossible; do not promise it. Map tiles are OpenStreetMap (labels = OSM data). Google-grade labels need Google Maps
  SDK + a paid key (not done).
- Telegram sign-up screens (earlier patch): `OtpRequest`, bot link only if `https://t.me/...`.
- Input checks on the phone (defence in depth; the server enforces the same): `PillField` takes `inputFormatters`;
  phone fields accept only `[0-9+\-\s().]` up to 24 characters, code and PIN fields are digits only, and
  `onboarding_controller.dart` refuses a code that is not `^\d{6}$` (`otp.format`), a PIN outside `^\d{4,8}$`
  (`pins.format`) or a PIN that does not match its confirmation, and a phone that `normalizePhone` rejects (`phone.invalid`).
  New strings `phone.invalid` and `otp.format` in all five languages (AI-written, needs a native review like the rest).
- New tests: `net_resilience_test.dart`, `place_lookup_test.dart`, `police_numbers_test.dart`, `onboarding_test.dart` (extended,
  including every rejection above).
Backend
- `modules/auth/otp.ts` `issue()`; `modules/telegram/{api,bot,routes,secret}.ts`; env: `OTP_PROVIDER`, `TELEGRAM_*`
  (webhook secret derived from TOKEN_SECRET when unset); `PUBLIC_BASE_URL` falls back to `RENDER_EXTERNAL_URL`.
- Persistence/robustness: `DATA_KEY` and `PHONE_HMAC_KEY` accept 64 hex OR base64 (Render's generated values) via `toHexKey`;
  `db/migrate.ts` pool has an `error` handler, timeouts, `statement_timeout` 20 s; `unhandledRejection` is logged, not fatal;
  graceful shutdown already existed.
- Security hardening: error handler maps PostgreSQL "data exception" SQLSTATE class 22 (malformed uuid, NUL char) to 400
  instead of 500; SOS update uses `Object.hasOwn(COLS, k)`; `fixes trustProxy` typing (`app.ts`).
- New tests: `sql-safety.test.ts` (guard), `hostile-input.test.ts` (injection strings, NUL, wrong types, oversized, broken JSON
  on every route), PG integration tests for hostile text (real tables), `telegram.test.ts` (keys, Render env).
- `render.yaml` gets `buildFilter` (only backend changes redeploy: an app-only update must not wipe the free server);
  `render.live.yaml` is the permanent setup.

## 6. Verified vs NOT verified
Verified in the sandbox: `tsc` clean; 237 backend tests; 31 real-Postgres tests (PostGIS); the built server run on real
Postgres + Redis with Render-style base64 secrets: an account, pins and 3 contacts survived a clean restart AND a SIGKILL;
the phone number is not readable in the database; 1,794 hostile HTTP requests (rate limits patched out of a COPY of dist only)
gave zero 5xx, zero error logs, no input echoed, tables intact; actionlint on workflows; all Dart files parse (tree-sitter) and
the five language files agree.
NOT verified: any Dart compilation or Dart test run; the Render deploy of `render.live.yaml` (field names/plans checked
against Render docs and search results only); Paystack anything; Firebase push; device behaviour of `geocoding`.
Expect the first CI build of this patch may show Dart errors. Fix from the run annotations.

Checked for the input-hardening patch, without a compiler: the patch applies to main `50d0773` and every changed file ends up
with the blob hash the patch declares (a PowerShell script re-implements `git apply` and hashes the result, so the patch is
known to fit); the five language files have the same keys and the same `{placeholders}` with no duplicate keys; the police
JSON still satisfies `police_numbers_test.dart` and the data assertions in `police_map_test.dart` (37 commands, none
`verified`, every one `npfListed`, first three lines of each dialable, Lagos order, eight commissioners with notes).

## 7. Traps already discovered
- Free Render service sleeps after 15 min and wipes memory on restart. That caused "connection error after a while" and
  vanishing accounts. The app's old 8 s timeout made the first request after sleep always fail.
- `apply-patch.yml` cannot push workflow files; uploaded `.txt` copies are ignored by GitHub until renamed to `.yml`.
- Contact rule is 3 to 5 contacts (`MIN_CONTACTS`/`MAX_CONTACTS` in `backend/src/modules/auth/phone.ts`). A "10 contacts" Pro tier needs
  that changed and the app's contact screens too.
- Production mode (`NODE_ENV=production`) refuses `SMS_PROVIDER=mock` and `OTP_DEV_ECHO`; both blueprints use `development`.
  Postgres storage works in either mode.
- SOS alerts reach contacts in the app via push (FCM). `PUSH_PROVIDER` is not configured: without Firebase, contacts only see
  alerts when they open the app. Real-time delivery is a go-live blocker (section 8.4).
- `SMS_PROVIDER=mock` + `DISPATCH_MODE=log`: nothing is texted and police are not contacted automatically.
- 429 from the server in fuzz tests is the rate limiter working; relax limits only in a copy of `dist`, never in source.

## 8. Next steps, in order
8.1 Apply this patch (section 3). Read the APK build annotations. Fix Dart compile/test errors.
8.2 App-side input hardening: DONE in this patch (see section 5). Kept as a checklist: `PillField` has `inputFormatters`;
    the code field is digits only + 6, PIN fields digits only + 8, phone fields filter characters + 24; the controller refuses
    a bad code, a bad PIN or a bad number before any request. The server still validates everything itself.
8.3 Permanent hosting so the server never forgets: use `render.live.yaml` (Render > New > Blueprint > Blueprint Path =
    `render.live.yaml`; enter the bot token + username; ~$23/month). Then: set Key Value eviction to `noeviction`; copy the new
    address into the repo secret `API_BASE_URL`; rebuild the APK; delete the old free service. The Telegram webhook re-registers on
    start. Back up `DATA_KEY`, `PHONE_HMAC_KEY`, `TOKEN_SECRET` somewhere safe (losing them makes stored data unreadable).
    Add Postgres+Redis service containers to `apply-patch.yml` so CI also runs `pg.integration.test.ts`
    (images `postgis/postgis:16-3.4` and `redis:7`; env `TEST_DATABASE_URL`); Vic must upload that workflow by hand.
8.4 Real-time alerts: create a Firebase project, add `google-services.json` to the Android build (workflow step from a base64 repo
    secret), set the server's FCM service-account env (see `backend/.env.example`), set `PUSH_PROVIDER=fcm`. Test with two phones.
    Optional later: Termii SMS (Nigerian provider) for OTP fallback, then `NODE_ENV=production`.
8.5 Monetisation (design agreed with Vic's intent; not built). Paystack is the gateway (card, bank transfer, USSD, QR; fees 1.5% +
    N100 on payments of N2,500 or more, so about N12 on N799 and N475 on N25,000; bank transfer/USSD cannot auto-renew, so sell
    "a month at a time" and add card auto-renew later).
    Hard guard: billing must refuse to enable unless `STORE=postgres` (a paying customer must never be forgotten).
    Prices in kobo: monthly 79900, lifetime 2500000 (suggest a "Founders" cap of 500).
    Build: migration `006_billing.sql` (payments with unique reference, subscriptions), `modules/billing` (plans, store memory+pg,
    Paystack client with fetch + timeout, routes `GET /v1/billing/plans`, `GET /v1/billing/status`, `POST /v1/billing/checkout`,
    `GET /v1/billing/verify?reference=`, `POST /v1/billing/paystack/webhook` verifying `x-paystack-signature` = HMAC-SHA512 of the RAW
    body with the secret key, idempotent by reference, amount/currency check, then confirm with Paystack's verify API),
    env `PAYSTACK_SECRET_KEY`. Paystack needs an email: use a configurable placeholder or let the user add one.
    Entitlements are enforced on the SERVER, and only once billing is enabled (otherwise everyone keeps full features).
    Principle: safety stays free (SOS, police numbers, 112, map, test alert, 3-5 contacts, sharing). Pro (N799/month): Safe Arrival
    check-in timer (auto-alert if not confirmed), more contacts (needs the 3-5 limit changed), 24 h sharing, trip history.
    Do not sell features that do not exist yet. App: Upgrade screen, plan state from `/v1/billing/status`, open Paystack checkout in a
    browser tab, poll status on return. All strings in 5 languages.
8.6 Maps: if Vic wants Google-quality labels, add Google Maps SDK (key restricted to the app, passed as a build secret, manifest
    placeholder) behind a fallback to OSM. Until then, optionally use a keyed tile provider via a `TILE_URL` dart-define.
8.7 Police data: spot-checked 6 states against the NPF published list (all matched); the rest are unchecked. Lagos control-room
    numbers added from the Command's own site. Commissioner names are from news reports; keep them optional.

## 9. Security checklist for any new code
Zod-validate body, query and params. Bound SQL parameters only (guard test). Constant-time compare for secrets/signatures.
Verify webhook signatures on the raw body. No secrets or phone numbers in logs. Errors return `{error: code}` only.
Rate limit anything that costs money or sends messages. Keep `bodyLimit` small. Escape any HTML (the only HTML is the static admin page).

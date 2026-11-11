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
- Contact rule is 2 to 6 contacts (`MIN_CONTACTS`/`MAX_CONTACTS` in `backend/src/modules/auth/phone.ts`). Two are needed at sign-up;
  the remaining four are added inside the app (up to the six cap). A "10 contacts" Pro tier needs
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

## 10. Version 26 (this patch) — engineer's notes
Style rule for the whole app: FLAT. No frosted glass, no translucency. `core/widgets/glass.dart` kept its class names
(`Glass`, `GlassBackdrop`) but paints a solid panel now; do not reintroduce blur.
- Immediate SOS: `modules/sos/engine.ts` sends the first round of alerts the moment SOS starts
  (`tick()` runs right after ACTIVATE is scheduled; first round itself `repeatCount: 0`). The countdown on the phone is
  only the CANCEL window — contacts are already alerted. `ackEvent` accepts `countdown`; cancel PIN works from
  `countdown`, `active` and `acknowledged`. First-round repeats stay `[3,3,3]`; duress-window repeat shows `repeat: 1`.
- The phone starts the SOS faster too: `sos_controller.dart` `_startServer` uses `_tryStart` with the last-known GPS,
  then refines the fix and sends location again.
- Every contact push vibrates like an alarm (channel `vibrationPattern` set once at channel creation, including the
  live-share channel). Water reminder: re-arms only when the same pace is not already pending, and exact-alarm permission
  is requested best-effort. Water status bug fixed (`_waterId` int compare).
- Share history: new `GET /v1/shares/history` (registered BEFORE the `:id` routes — order matters). Store→service→route
  pattern like the rest of `modules/share`; `ShareStore.history(userId, limit)` clamps 1..50. The share screen shows it
  under the picker (header reuses the old `exercise.history` strings — dead keys were repurposed, NO new i18n keys exist).
  Old strings given new jobs in the SAME keys: `police.reported/unverified/to_confirm/unconfirmed` are now the four
  time-of-day greetings used by `home_screen.dart` `_greetKey()`; `health.allow` is the profile "name" label;
  `health.heart_perm` is the profile photo note; `pins.must_differ` is the empty share-history note;
  `sos.countdown` now says the alert is ALREADY out. Key parity is still exactly 287 keys × 5 locales.
- Profile: `core/profile.dart` (name + avatar kept in SecureKeyValueStore keys `profile.name.v1`/`profile.avatar.v1`;
  the photo NEVER leaves the phone; `setName` mirrors the name to the server best-effort and offline saves stick).
  `image_picker: ^1.1.2` picked the photo; the circle crop happens at display time. New Dart class added to `SentriApi`
  (`shareHistory()`, `saveProfile`) means `mobile/test/helpers.dart` FakeApi must implement them — rule 6 again.
- Home is a flat mood face (CustomPaint `_MoodFacePainter`, green→red while the SOS hold runs), greeting + avatar +
  `_ProfileSheet`; the old unwired `CheckInCard` was deleted from that file. Bottom nav is a custom floating flat pill
  (`_PillNav` in `app.dart`, still an IndexedStack). Police screen got real one-tap call buttons (`url_launcher tel:`,
  numbers made dialable via `_dialable`). `FlatPage` gained `physics:`/`onScroll:` for the bouncy scroll + parallax
  banner (share + police screens). Photos in banners feature Black models (standing rule).
- Reinforce this here: a closure capture defeats null promotion — assign to a `final` local first. Also: CJK or
  odd identifiers must NEVER leak into code files (a "大部" byte slipped into a draft once; caught and removed).

## 11. Version 27 (this patch) — engineer's notes
Vic's fix list: live kilometres, live map path, path in history, app-wide scroll feel, the home face (red SMIRK
not anger + a blink every 2 s), and the SOS screen now in the flat family. No i18n changes: still 287 keys × 5.
- Exercise tracking is stream-first. `location.dart` has `LocationSource.positions({double distanceFilterM = 5})` —
  Geolocator `getPositionStream(accuracy: bestForNavigation, distanceFilter: …)`. The default abstract impl throws
  `UnsupportedError`; `FakeLocation` returns an empty stream. `exercise_controller.dart` `_track()` listens to it
  (and centres the map instantly on `lastKnown()`); every stream entry goes through `_onPosition()`. Fallback
  `_startFallback()` keeps the old one-fix-per-5-s poll (`_pollFix()`) only when the stream errors, closes or the
  source cannot stream. Count gates: accuracy ≤ 60 m (`_maxAccuracyM`), movement below the average of the last two
  accuracies is noise (ignored), movement beyond `mode max speed × dt + 15 m` is a GPS jump (dropped, anchor kept).
  km += moved/1000 and `_appendPoint` at every accepted fix ≥ 0.5 m; path entries need ≥ 8 m; max 300 points, thinned
  by halving (start+end kept). `stop()`/`start()`/`dispose()` all cancel `_posSub` + both timers.
- The map already followed `lastFix` and history already showed `record.path` (`_showSession` bottom sheet) — the
  bug was only that nothing was ever accepted, so both looked dead. No workout/health-screen changes needed.
- Scroll feel: `FlatPage` default physics is now `AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics())`.
  Same physics added to home, health (+ parallax on the banner via `_scrollY` state), contacts (3 lists), map (2
  spring sheets), onboarding, SOS, and the health awards shelf row. Reduced-motion users are unaffected (only our
  custom painters check `Flat.still`).
- Home face: `_MoodFacePainter` moved to `flat.dart` as public `MoodFacePainter(hold, ink, blink)`; hold ≥ 0.5 is a
  RIGHT-LIFTED SMIRK (asymmetric curve), never the old flat grimace. `_HomeScreenState` runs a second controller that
  repeats every 2 s; `_blinkValue()` shuts the eyes for ~440 ms of that (sine curve), and `Flat.still` keeps the face
  motionless. `widget.sos` joined the `Listenable.merge` — while `sos.phase != SosPhase.idle` the face field stays
  red with the smirk (mid-hold too).
- SOS screen redesigned: mood-face disc (white on alarm red; seconds in the disc during countdown; green + check
  once contacts acknowledge) inside a thin countdown ring, `Flat.bg` ground, hairline offline chip, `FlatButton` for
  "I'm safe", everything in `pin_pad.dart` (new leaf; `PinPad`/`PinPadState` API unchanged: `clear()`, `enabled`,
  4-digit auto-submit) as flat card keys with hairline edges and alarm-red dots. PoliceCallCard untouched.

## 12. Version 28 (this patch) — engineer's notes
Vic's polish list: circled home functions, a visible profile with the app's own picture icons, pinpoint map
accuracy, and a lighter Health banner shading. No i18n changes: still 287 keys × 5.
- Home menu: the three grey rows became `_CircleTile`s in a Row — a 64 px card disc (hairline edge) with the icon
  in brand indigo and the existing `share.title`/`contacts.title`/`triggers.title` label UNDERNEATH, two lines
  capped. The share circle carries a LiveDot badge while a share runs (`widget.share.active != null`); the old
  `_MenuRow`/`_SharingTag` were deleted.
- Profile is visible: `_Avatar` grew a pencil badge (`showEdit: true` on the greeting) and the sheet is a bigger,
  bouncy, 0.78-height scrollable with the 50-icon grid. Gallery still works (photo_library badge on the big
  preview; `setAvatar` wins). The 50 faces live in `core/widgets/avatar_icons.dart` (NEW LEAF): SentriAvatar /
  SentriAvatarPainter — 5 skin tones × 10 hairstyles (5 female: long, afro puff, braids, bun+swep, hijab;
  5 male: crop, waves, afro, bald+beard, locs) × 10 pastel grounds, drawn in code so nothing ships as an image.
  `Profile` persists `profile.avatar.icon.v1` (index) + `profile.avatar.icon.on.v1` (last-choice flag:
  `setIcon` turns it on, `setAvatar` turns it off — the LAST choice wins, and the photo is never deleted).
- Map pinpoint: `_MapScreenState._startRefinement()` listens to `LocationSource.positions(distanceFilterM: 2)`
  and applies a fix when it is ≥1 m more accurate or the person moved 25 m — the ±100 m ring tightens within
  seconds of opening the tab. Fakes return an empty stream (already in test_helpers); dispose cancels `_refineSub`.
- Health banner: gradient cut from 70 % black to 25 % and the title got its own soft text shadow — the words
  stay readable on any photo without the dark wash.
- Lesson re-confirmed: arrow-`=>` builders cannot become brace bodies by half (stray `),` / `);` broke
  home_screen in v27's first CI round); and `SizedBox` has no `alignment` (pin_pad needed `Container`).

## 13. Version 29 (this patch) — engineer's notes
Vic's follow-ups: show the clipped home texts fully, give the 50 faces real personality, and make the whole
app scroll like the reference reel with icons that react when tapped. No i18n changes: still 287 keys × 5.
- Clipped texts: the greeting hero line (`home.hero` is long) now wraps to two lines at 17.5 w800 instead of one
  20 px clipped line; the three home circle tiles each sit in an `Expanded` third of the Row so "Ways to call for
  help" wraps inside its own space and never runs off the screen edge (label 12 px, 2-line cap kept).
- Face personality: `SentriAvatarPainter` rewritten — on top of skin/hairstyle/ground, each index derives traits
  by modulo arithmetic on different primes: round or square glasses, one raised brow, blush, freckles, a beauty
  mole, open-grin / gentle / lopsided-smirk mouths (lip colours on the women), nose, eye sparks, earrings, bead
  colours on braids, bun tie ring, hijab fabric palette + trim band, afro sheen arcs, and men carry stubble,
  goatees, moustaches (the bald one keeps the full beard + moustache). All 50 stay deterministic and distinct.
- Excited taps: new `TapBounce`/`TapBounceState` in `flat.dart` (shared) — a 480 ms squash-jump (translate −5 px,
  scale 1→0.90→1) with a two-shake wiggle (sin 4πt, 0.07 rad), disabled under `disableAnimations`. Wired into the
  `_PillNav` items (home/map/health/police hop then settle into their chip) and the home `_CircleTile`s (which
  drop their InkWell for it). `TapBounceState.excite()` fires it without a tap if a caller ever needs that.
- Scroll feel: `FlatPage` default physics is now `AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics(
  decelerationRate: ScrollDecelerationRate.fast))` — the elastic snap-back of the reference reel, app-wide; home
  already bounced and keeps its own physics line.
- i18n untouched; no new persistence keys (the 50-icon pick from v28 is unchanged).

## 14. Version 30 (this patch) — engineer's notes
Vic's ask: the History section becomes one visible tap that opens the WHOLE exercise story - every walk/run/ride
session, its route like the Strava reference, and the awards. Sleek. No i18n changes: still 287 keys × 5.
- Health tab: the History card's whole header is now a `TapBounce` target with a chevron (total-km text stays);
  it pushes the new `ExerciseHistoryScreen`. Entries in the preview now open the session page directly (the old
  bottom sheet `_showSession` is gone).
- `ExerciseHistoryScreen` (same leaf): `FlatPage` titled `exercise.history` with the total-km line as subtitle,
  the shared award shelf card on top, then one card listing EVERY session (mode disc icon, `Walk · on d/m`,
  km · min · steps, chevron) → each opens the detail page.
- `_SessionDetailScreen`: Strava-style stat strip (three columns - distance big, time as mm:ss tabular, steps or
  `—` for bike; labels reuse `exercise.distance/time/steps`), then the route nearly full-bleed (280 px,
  rounded 24) via `FlutterMapSheetMap(path, ends: true)` - new start/end pins (green start, indigo end, white
  edge) over the existing indigo polyline; then the award shelf again. All existing keys, nothing new.
- `_AwardShelfCard` extracted from the tab's `_awardsCard` (identical look) so the shelf is shared three ways;
  the tab's card now just delegates.
- i18n untouched; no new persisted keys; `WorkoutRecord`/`AwardStore` APIs unchanged.

## 15. Version 31 (this patch) — engineer's notes
Vic's asks: fix the broken Yoruba in the health section, redesign the Messages screen to the activity-feed
reference, and give sign-up the floating-elements welcome. i18n still 287 keys × 5 — VALUE EDITS ONLY.
- Yoruba fixed: 16 lines of i18n-yo.json were double-encoded mojibake ("IbÃº okan" etc.) — heart-rate, water and
  nearby-hospital strings plus `tabs.health` ("Ìlera"). Rewritten with proper Yoruba diacritics (ibí okan,
  ìṣẹ́jú, pàjáwìrì...); keys untouched, parity check passes 287 × 5. No other locale carried mojibake (scanned).
- Messages screen (`features/inbox/inbox_screen.dart` — NEW LEAF, taken from the head tree): each message is now
  its own Card instead of a FlatGroup row — a 46 px gradient disc (danger tones for live urgent, indigo
  otherwise), the text bold when unread, a chip row under it (a green LiveDot pill `inbox.live` while an alert
  runs, a hairline clock chip with the `inbox.now/min/hr/day` age, tabular digits), a trailing unread dot or a
  quiet check. Invites, scam note, test-alert button and AlertDetailScreen are untouched. No new keys.
- Sign-up welcome (`features/onboarding/onboarding_screens.dart`): a new `_FloatingField` (stateful, one
  repeating 4.2 s AnimationController, off under `disableAnimations`) floats two SentriAvatar faces (indices 2
  and 27, white-ringed with a soft shadow) among three gradient tool bubbles — alert bell, location pin,
  shield — each bobbing on its own sine phase above the phone step. The phone form itself sits in one rounded
  24 card (hairline edge, soft shadow) wrapping the PillField + PillButton, like the reference's bottom card.
  All text still `phone.title` / `phone.help` / `phone.send_code`.
- Pipeline notes: inbox_screen.dart joined the leaf table; check-apk20 gained a `FloatingField` libapp.so needle
  and a Yoruba-health check (bundled yo.json must contain the corrected `Ibí okan` and no U+00C3 mojibake).



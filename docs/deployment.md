# Sentri deployment guide (Phase 1)

Nothing here has been run end to end yet. Treat it as a checklist to verify in a staging environment first.

## 1. Components
| Piece | Image / service | Notes |
|---|---|---|
| API + workers | `Dockerfile.backend` (Node 22) | Stateless. Run 2+ replicas behind a load balancer. |
| PostgreSQL 16 + PostGIS | managed or self-hosted | Holds users, SOS events, audit log, police directory. |
| Redis 7 | managed or self-hosted | BullMQ repeat-loop queue. Enable persistence (AOF) so scheduled repeats survive restarts. |
| SMS | Termii (via `SmsProvider`) | Only for sign-in codes and police dispatch. Alerts to contacts never go by SMS. Needs a registered sender ID. |

## 2. Environment variables
Copy `backend/.env.example`. Production refuses to start with the memory store, dev switches (`OTP_DEV_ECHO`, `DEV_SEED`) or the mock SMS provider.

Generate secrets (never commit them):
```bash
openssl rand -hex 32   # JWT_SECRET
openssl rand -hex 32   # DATA_KEY  (AES-256-GCM for phone numbers)
openssl rand -hex 32   # PHONE_HMAC_KEY (64 hex, blind index)
```
Store them in your cloud secret manager. **Losing DATA_KEY or PHONE_HMAC_KEY makes stored phone numbers unreadable.** Back them up separately from the database. Plan key rotation before launch (re-encrypt job not built yet).

## 3. First deploy
1. Provision Postgres (enable `postgis`) and Redis.
2. Set env vars, `STORE=postgres`, `NODE_ENV=production`.
3. Run migrations: `node dist/db/migrate.js`.
4. Start API replicas; check `GET /healthz`.
5. Put TLS in front (load balancer or reverse proxy). Redirect HTTP to HTTPS. Set HSTS.
6. Send yourself a test SOS from a staging build with the police dispatcher on `log_only`.

## 4. Data residency
- Nigeria launch: host in a Nigerian or nearby African region if your provider offers it, and keep database, Redis, backups and logs in the same region.
- One deployment per jurisdiction (NG now, EU later) with its own database and keys. Do not replicate user data across regions.
- Back-ups: encrypted, same region, short retention matching the data retention policy.

## 5. Operations
- **Retention:** a built-in job (`RetentionJob`, one instance at a time via a Postgres lock) deletes finished SOS events and their location points after `RETENTION_HOURS` (default 72), plus expired OTPs, revoked devices after 30 days, and deleted accounts after 30 days. Set `RETENTION_HOURS` to what your privacy notice says.
- **Audit log:** hash-chained. Export daily to write-once storage. Run the chain verification before any investigation.
- **Access:** no single admin should be able to read user data. Until dual approval is built, restrict database access to break-glass accounts and log every use.
- **Monitoring:** alert on failed SMS sends, queue lag above 10 s (repeat loop is 25 s), SMS budget above 80%, 5xx rate, and Redis memory.
- **Load test** the repeat loop with realistic concurrent SOS counts before launch.
- **Rate limits:** tune per-IP and per-phone limits for OTP and SOS after observing real traffic.

## 6. Mobile release
- Android: build with `--dart-define=API_BASE_URL=https://api.yourdomain`, release signing, Play Console declarations (see legal checklist).
- iOS: App Store build, Action Button / Back Tap instructions in onboarding help.
- Ship behind a closed beta (Play internal testing / TestFlight) with real devices across Tecno, Infinix, Samsung and Xiaomi; some vendors kill background services aggressively.

## 7. Go-live gates
- [ ] Backend tests green (`npm test`) and Flutter tests green (`flutter test`)
- [ ] Postgres integration tests green (`npm run test:integration` against a throwaway database)
- [ ] Staging soak test passed, repeat loop and in-app 'I'm responding' verified on real phones, including a locked phone in Doze
- [ ] Police directory populated only with officially verified numbers, dispatcher still `log_only` until the MOU is signed
- [ ] Translations reviewed by native speakers
- [ ] Legal checklist items 1 to 6 complete

## 8. Place names and map tiles
- **Place names (street, area, LGA, state):** run your own Nominatim loaded with the Nigeria extract (`nigeria-latest.osm.pbf` from Geofabrik), in the same region as the API. Set `GEOCODER=nominatim` and `NOMINATIM_URL`. Do not point real users at the public nominatim.openstreetmap.org (rate limits, and it would see every user's position). The lookup is optional: alerts never wait for it.
- **Map tiles:** the public OSM tile server is for development only. For release use your own tile server or a paid provider, and pass `--dart-define=TILE_URL=https://tiles.example.com/{z}/{x}/{y}.png`. Keep the "© OpenStreetMap contributors" credit.
- **Police directory:** `mobile/assets/directory/police_directory.json` ships every state's lines as `npfListed: true` (they match the list the Nigeria Police Force itself published) but `verified: false`, because nobody has called them and that list is undated. The app shows "Listed by NPF", never "Verified". Call each line, get the command to confirm it, then set `verified` with `verifiedAt` (see the three-step flow below).

## 9. Push notifications, consent and tests
- **Push (Firebase):** create a Firebase project, download a service-account key, then set `PUSH_PROVIDER=fcm` and `FCM_SERVICE_ACCOUNT_B64=$(base64 -w0 service-account.json)`. The Flutter app already registers its token (`PUT /v1/me/push-token`) once `google-services.json` / `GoogleService-Info.plist` are added; see `mobile/SETUP.md` section 6. Pushes are data-only, high priority and carry no link. Alerts reach emergency contacts only inside the app (inbox plus a ringing, vibrating push), so a text that claims to be a Sentri alert is always fake. A contact without the app cannot be alerted; the owner sees who is reachable and can invite them.
- **Testing sign-up codes:** (1) no SMS account yet: set `OTP_DEV_ECHO=true` with `SMS_PROVIDER=mock`; the server prints the code and returns it to the app, which shows "Test mode: your code is …" (tap to fill). Production refuses to start with this on. (2) real texts: set `SMS_PROVIDER=termii`, `TERMII_API_KEY`, `TERMII_SENDER_ID`, then run `npm run sms:test -- 0803xxxxxxx` to send one test text and see Termii's reference or the exact reason it failed (key, sender ID, balance, DND route). Sign-up then works end to end; the app offers "Send a new code" after 30 s.
- **Alert behaviour:** contacts get an inbox item plus a data-only high-priority push (collapse key = alert id, TTL 10 min). When a contact responds or the person cancels with their real PIN, a `clear` push stops the ringing on every contact's phone (not sent on a duress PIN). Offline alerts are queued on the phone and sent when it is online. Police numbers near the position are shown to the person and their contacts with dial buttons; they are unverified and matched by distance to the state capital.
- **Contact invitations:** when someone is added as a contact and already has Sentri, they see an invitation in the app and can accept or decline. No SMS is sent. Declined contacts never receive alerts. Contacts who have not answered still do, so an unanswered invitation never silences a real emergency. Decide with your lawyer whether that default fits NDPA consent rules.
- **Database tests:** `TEST_DATABASE_URL=postgres://user:pw@localhost:5432/sentri_test npm run test:integration`. The database name must contain "test" and is wiped at the start of the run.

## 10. Admin access (two-person rule)
- Turn it on with `ADMIN_JWT_SECRET` (a new secret, different from the user secrets). Without it the admin API does not exist.
- **First two admins:** on a trusted machine with database access run `npm run admin:create -- alice@example.ng`, then again for a second person. Each gets a one-time password and an authenticator-app secret. Hand these over in person or through a password manager, never by SMS or chat. The script refuses to create a third admin: after that, new admins are added through an approved `admin_add` request.
- **What needs two people:** adding or editing a police entry, verifying it, retiring it, adding or removing an admin (one other admin approves), and reading a user's recent alert history (two other admins approve). The requester can never approve their own request, one rejection ends it, requests lapse after 24 hours, and a data-access grant lasts 1 hour and can only be used by the requester. Every step goes in the audit log without any personal data in it.
- **What an investigator can read:** the user's recent alert records (state, trigger, times, last location). Not phone numbers, PIN data or the duress flag.
- **Database access is still the weak point.** Anyone with direct database and key access can bypass the app. Keep the database credentials and the `DATA_KEY` with different people, log database sessions, and review them.
- The admin API is under `/admin/v1/` and the console page is at `/admin`. Keep both behind a VPN or an allow-list at the load balancer.

## Are the police alerted?

No. The app alerts emergency contacts only. Police are reached by the person or a contact tapping the call buttons (112 and the nearest command's lines). The automatic police SMS path in the server (`DISPATCH_MODE=sms`) must stay off until a command or the Force gives you an official intake line in writing and you have an agreement. Do not describe Sentri as alerting the police until then.

## 11. Admin console and the police directory
- **Open `/admin`** and sign in with email, password and the authenticator code. Sessions last 15 minutes. The page has no data in it and a strict Content-Security-Policy (no inline handlers, no external files); the session token is kept only in the page's memory.
- **Tabs:** Requests (answer, approve, reject, carry out), Police directory (search, add, edit, verify, retire), New request (user-data access, add or remove an admin), Team.
- **Editing the directory is a three-step flow, each step needing a different person:** (1) someone proposes an entry or an edit with a *source* (letter reference, official page, call log) and it is approved by a second admin; (2) the saved entry is **unverified** and receives no alerts; (3) after someone actually calls the command to confirm the number, a verification request is raised and approved by another admin. Changing a number later clears verification, so it must be confirmed again. Retiring stops routing and keeps the record.
- **Two directories exist, on purpose.** The app ships `police_directory.json` (what the Police tab shows on the phone, `verified:false` until you edit it). The server's `control_rooms` table is what the dispatcher uses to route an alert, and is managed here. Keep them consistent: when an entry is verified here, update the bundled JSON in the next app release.
- **Area boundaries:** migration 004 adds the 36 states and the FCT as names only. Location-based routing needs polygons. Import state (and, later, LGA) boundaries from an open source such as geoBoundaries ADM1/ADM2 for Nigeria (check its licence and keep the credit) into `admin_areas.boundary`. Until then the lookup finds nothing and the country emergency line is used, so add and verify one `emergency_line` entry first. The dispatcher stays `log_only` until the MOU is signed.
- **Numbers are validated for shape only** (digits, optional +, 3 to 18 characters). That cannot tell a real police line from a wrong one; the source field and the verification step are the control.

## 12. Known gaps to close before a pilot
- **No name on alerts.** Contacts are told "someone needs urgent help" and shown a position, but not who. Add an optional "name your contacts know you by" at onboarding, stored encrypted like phone numbers, and show it on the contact page and in the first text. Check text length stays under 160.
- **Contact pages use OpenStreetMap's public embedded map** for the picture. That is fine for a pilot; for scale use your own tile server (section 8) and a self-hosted map component.
- **Location is not field-encrypted** on the alert record (see `docs/paperwork-drafts.md`, section A).

## 10. Live location sharing and sleep-mode triggers
- **Sharing:** `POST /v1/shares` starts a share with chosen contacts (they must have the app); `PUT /v1/shares/:id/location` updates the latest position (only the latest is stored, never a trail); `DELETE /v1/shares/:id` stops it. Contacts get an in-app message and a push on start and on stop. A share ends by itself after 8 hours by default (24 h maximum, the owner can extend) and a one-minute sweep tells contacts when it expires. Rows are removed by the retention job.
- **Triggers on a sleeping phone (Android):** the protection service keeps one Flutter engine warm, so a shake, volume or button gesture starts the alert with no screen. The cancel-PIN screen then attaches to the alert already running. Needs: always-on location, battery optimisation off, overlay permission, and the accessibility service for volume. Some makers (Xiaomi, Tecno, Infinix, Oppo, Vivo) still kill background services; users must allow auto-start and lock the app in recents.
- **iPhone cannot do this:** iOS does not allow watching buttons or the accelerometer in the background. On iPhone, use the SOS button, a Shortcut or the Action button.

## Behind a hosting proxy

Most hosts put a reverse proxy in front of your server. Set `TRUST_PROXY_HOPS=1` (the number of proxies) so rate limits see each caller's real address. Leave it at 0 only when callers reach the server directly. See `docs/security.md` for the full list of protections and open items.

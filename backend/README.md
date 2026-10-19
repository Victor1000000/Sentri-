# Sentri backend

Step 1a: SOS engine, PIN logic, SMS provider, budget guard, police directory, HTTP API.
Step 1b: Postgres/PostGIS store + migrations, phone verification (OTP), device auth (JWT + rotating refresh tokens),
onboarding endpoints, BullMQ scheduler, encrypted phone numbers at rest, hash-chained audit log in Postgres.

## Run in memory (no services needed)
    cp .env.example .env     # set TOKEN_SECRET, PIN_PEPPER, JWT_SECRET (openssl rand -hex 32)
    npm install
    npm run typecheck && npm test
    set -a; . ./.env; set +a
    DEV_SEED=true OTP_DEV_ECHO=true npm run dev

## Run for real (Postgres + Redis)
    docker compose up -d                      # from the repo root: PostGIS + Redis
    # in .env: STORE=postgres, DATA_KEY and PHONE_HMAC_KEY (openssl rand -hex 32 each)
    npm run migrate                           # also runs automatically on start
    npm run dev

## Sign-up flow (what the app will call)
    POST /v1/auth/otp/request   {phone}
    POST /v1/auth/otp/verify    {phone, code, platform, publicKey, boxPublicKey}  -> accessToken, refreshToken, deviceId
    POST /v1/auth/refresh       {deviceId, refreshToken}
    PUT  /v1/me/contacts        {contacts:[{phone, locale?} x3..5]}
    PUT  /v1/me/pins            {cancelPin, duressPin}
    PUT  /v1/me/profile         {locale?, dataSaver?}
    PUT  /v1/me/push-token      {token}
    POST /v1/sos                {trigger, lat?, lon?}      (Authorization: Bearer <accessToken>)
    POST /v1/sos/:id/pin        {pin}
    POST /v1/sos/:id/location   {lat, lon, accuracyM?}
    POST /v1/alerts/low-battery {lat?, lon?}
    GET/POST /r/:token          contact "I'm responding" page

Keys (publicKey, boxPublicKey) are base64 of 32 raw bytes.

## Not yet verified
PgSosStore, PgAudit, PgDirectory, PgUserRepo and BullScheduler have no automated tests yet: they need a live
Postgres/Redis. Run the app against `docker compose` once and exercise the sign-up flow above before trusting them.
EOF

-- Sentri schema, migration 001.
-- Times are epoch milliseconds (BIGINT) to match the application model exactly.
-- Phone numbers are never stored in the clear: *_hmac is a keyed blind index for lookup,
-- *_enc is AES-256-GCM ciphertext for sending.

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE users (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  phone_hmac   BYTEA NOT NULL UNIQUE,
  phone_enc    BYTEA NOT NULL,
  locale       TEXT NOT NULL DEFAULT 'en' CHECK (locale IN ('en','ha','yo','ig','pcm')),
  cancel_pin   JSONB,                       -- {salt, hash}; set during onboarding
  duress_pin   JSONB,
  data_saver   BOOLEAN NOT NULL DEFAULT FALSE,
  created_at   BIGINT NOT NULL,
  deleted_at   BIGINT
);

CREATE TABLE devices (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  platform         TEXT NOT NULL CHECK (platform IN ('android','ios')),
  public_key       BYTEA NOT NULL,          -- Ed25519 identity
  box_public_key   BYTEA NOT NULL,          -- X25519, for end-to-end encrypted alerts
  push_token_enc   BYTEA,
  refresh_hash     TEXT NOT NULL,           -- sha256 of the current refresh token
  last_seen_at     BIGINT,
  revoked_at       BIGINT
);
CREATE INDEX devices_user_idx ON devices(user_id);

CREATE TABLE contacts (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  phone_hmac       BYTEA NOT NULL,
  phone_enc        BYTEA NOT NULL,
  locale           TEXT NOT NULL DEFAULT 'en' CHECK (locale IN ('en','ha','yo','ig','pcm')),
  has_app          BOOLEAN NOT NULL DEFAULT FALSE,
  priority         SMALLINT NOT NULL DEFAULT 0,
  consent_status   TEXT NOT NULL DEFAULT 'pending' CHECK (consent_status IN ('pending','accepted','declined')),
  UNIQUE (user_id, phone_hmac)
);
-- 3..5 contacts per user is enforced in the application (replaceContacts).

CREATE TABLE otp_challenges (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  phone_hmac   BYTEA NOT NULL,
  code_hash    BYTEA NOT NULL,
  attempts     SMALLINT NOT NULL DEFAULT 0,
  created_at   BIGINT NOT NULL,
  expires_at   BIGINT NOT NULL,
  consumed_at  BIGINT
);
CREATE INDEX otp_phone_idx ON otp_challenges(phone_hmac, created_at DESC);

CREATE TYPE sos_state AS ENUM ('countdown','active','acknowledged','cancelled','expired');

CREATE TABLE sos_events (
  id                     UUID PRIMARY KEY,
  user_id                UUID NOT NULL REFERENCES users(id),
  state                  sos_state NOT NULL DEFAULT 'countdown',
  duress                 BOOLEAN NOT NULL DEFAULT FALSE,   -- never returned to the client
  trigger_type           TEXT NOT NULL,
  started_at             BIGINT NOT NULL,
  cancel_window_ends_at  BIGINT NOT NULL,
  acked_at               BIGINT,
  acked_by               UUID REFERENCES contacts(id) ON DELETE SET NULL,
  ended_at               BIGINT,
  repeat_count           INT NOT NULL DEFAULT 0,
  last_geo               JSONB,                            -- {lat, lon, accuracyM, at}; purged with the event
  last_seen_at           BIGINT NOT NULL,
  offline_notified       BOOLEAN NOT NULL DEFAULT FALSE,
  dispatched             BOOLEAN NOT NULL DEFAULT FALSE,
  pin_failures           INT NOT NULL DEFAULT 0,
  pin_locked_until       BIGINT NOT NULL DEFAULT 0,
  purge_after            BIGINT NOT NULL
);
-- At most one live SOS per user. This is what makes "trigger twice" idempotent under concurrency.
CREATE UNIQUE INDEX one_live_sos_per_user ON sos_events(user_id) WHERE state IN ('countdown','active');
CREATE INDEX sos_purge_idx ON sos_events(purge_after);

-- One-tap ack links and location links. Only sha256(token) is stored.
CREATE TABLE links (
  hash        TEXT PRIMARY KEY,
  kind        TEXT NOT NULL CHECK (kind IN ('ack','loc')),
  subject     TEXT NOT NULL,
  contact_id  UUID NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
  expires_at  BIGINT NOT NULL
);
CREATE INDEX links_expiry_idx ON links(expires_at);

-- Police / emergency directory: OFFICIAL lines only. No officer or patrol locations, ever.
CREATE TABLE countries (
  code                      CHAR(2) PRIMARY KEY,
  name                      TEXT NOT NULL,
  default_emergency_number  TEXT
);

CREATE TABLE admin_areas (
  id            SERIAL PRIMARY KEY,
  country_code  CHAR(2) NOT NULL REFERENCES countries(code),
  level         SMALLINT NOT NULL,           -- 1 = state, 2 = LGA
  parent_id     INT REFERENCES admin_areas(id),
  name          TEXT NOT NULL,
  boundary      GEOGRAPHY(MultiPolygon, 4326)
);
CREATE INDEX admin_areas_boundary_idx ON admin_areas USING GIST (boundary);

CREATE TABLE control_rooms (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_area_id  INT NOT NULL REFERENCES admin_areas(id),
  name           TEXT NOT NULL,
  kind           TEXT NOT NULL CHECK (kind IN ('state_command','area_command','control_room','emergency_line')),
  official_phone TEXT,
  official_sms   TEXT,
  verified_by    TEXT,                       -- who verified the number against an official source
  verified_at    BIGINT,                     -- NULL = never routed to
  active         BOOLEAN NOT NULL DEFAULT TRUE
);

-- Tamper-evident audit trail (hash chain). No phone numbers or coordinates in here.
CREATE TABLE audit_log (
  id          BIGSERIAL PRIMARY KEY,
  at          BIGINT NOT NULL,
  actor       TEXT NOT NULL,
  action      TEXT NOT NULL,
  target      TEXT,
  prev_hash   TEXT NOT NULL,
  entry_hash  TEXT NOT NULL
);

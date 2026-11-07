-- One more in-app alert kind: a heart rate that climbs abnormally again and again.
-- The phone decides when this crosses the line; the server only forwards it, rate-limited.
ALTER TABLE inbox_items DROP CONSTRAINT IF EXISTS inbox_items_kind_check;
ALTER TABLE inbox_items ADD CONSTRAINT inbox_items_kind_check
  CHECK (kind IN ('sos','duress','offline','low_battery','test','share_start','share_stop','health_alert'));

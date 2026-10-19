-- Directory editing support, and the list of states so the admin console has areas to attach entries to.
ALTER TABLE control_rooms ADD COLUMN source TEXT;       -- where the number was confirmed
ALTER TABLE control_rooms ADD COLUMN updated_at BIGINT;

INSERT INTO countries (code, name, default_emergency_number)
SELECT 'NG', 'Nigeria', NULL WHERE NOT EXISTS (SELECT 1 FROM countries WHERE code = 'NG');

-- State names only. boundary stays NULL until real polygons are imported; until then
-- location-based routing finds nothing and the country emergency line is used instead.
INSERT INTO admin_areas (country_code, level, name)
SELECT 'NG', 1, v.name FROM (VALUES
  ('Abia'),
  ('Adamawa'),
  ('Akwa Ibom'),
  ('Anambra'),
  ('Bauchi'),
  ('Bayelsa'),
  ('Benue'),
  ('Borno'),
  ('Cross River'),
  ('Delta'),
  ('Ebonyi'),
  ('Edo'),
  ('Ekiti'),
  ('Enugu'),
  ('Federal Capital Territory'),
  ('Gombe'),
  ('Imo'),
  ('Jigawa'),
  ('Kaduna'),
  ('Kano'),
  ('Katsina'),
  ('Kebbi'),
  ('Kogi'),
  ('Kwara'),
  ('Lagos'),
  ('Nasarawa'),
  ('Niger'),
  ('Ogun'),
  ('Ondo'),
  ('Osun'),
  ('Oyo'),
  ('Plateau'),
  ('Rivers'),
  ('Sokoto'),
  ('Taraba'),
  ('Yobe'),
  ('Zamfara')
) AS v(name)
WHERE NOT EXISTS (SELECT 1 FROM admin_areas a WHERE a.country_code = 'NG' AND a.level = 1 AND a.name = v.name);

-- Allow the two new request kinds.
ALTER TABLE admin_requests DROP CONSTRAINT admin_requests_kind_check;
ALTER TABLE admin_requests ADD CONSTRAINT admin_requests_kind_check
  CHECK (kind IN ('directory_verify','directory_upsert','directory_retire','data_access','admin_add','admin_remove'));

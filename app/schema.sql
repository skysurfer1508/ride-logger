CREATE TABLE IF NOT EXISTS points (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  owner_sub TEXT NOT NULL DEFAULT '',
  device_id TEXT NOT NULL DEFAULT '',
  lat REAL NOT NULL,
  lon REAL NOT NULL,
  timestamp TEXT NOT NULL,          -- ISO8601, sortable
  speed REAL,                       -- m/s, may be negative/invalid
  altitude REAL,                    -- meters
  horizontal_accuracy REAL,
  vertical_accuracy REAL,
  motion TEXT,                      -- JSON array as text
  battery_level REAL,
  trip_id TEXT,                     -- NULL when no active trip
  ride_id INTEGER,                  -- backfilled once assigned to a ride
  raw_properties TEXT NOT NULL,     -- full properties JSON blob, for reprocessing/debugging
  received_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS rides (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  owner_sub TEXT NOT NULL DEFAULT '',
  device_id TEXT NOT NULL DEFAULT '',
  trip_id TEXT,                            -- NULL if gap-inferred
  start_time TEXT NOT NULL,
  end_time TEXT NOT NULL,
  distance_m REAL NOT NULL,
  duration_s REAL NOT NULL,
  avg_speed_mps REAL NOT NULL,
  max_speed_mps REAL NOT NULL,
  elevation_gain_m REAL NOT NULL,
  point_count INTEGER NOT NULL,
  polyline_simplified TEXT NOT NULL,       -- JSON array of [lat, lon]
  source TEXT NOT NULL CHECK (source IN ('trip_marker','gap_inferred')),
  app_reported_distance_m REAL,            -- from the app's own trip-end marker, cross-check only
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- ##POST_MIGRATION##
-- Everything below this marker is applied by db.py *after* the owner_sub
-- backfill migration runs, since these indexes reference that column and
-- CREATE TABLE IF NOT EXISTS above is a no-op (so doesn't add the column)
-- on a database that predates multi-user support.

CREATE INDEX IF NOT EXISTS idx_points_timestamp ON points(timestamp);
CREATE INDEX IF NOT EXISTS idx_points_trip_id ON points(trip_id);
CREATE INDEX IF NOT EXISTS idx_points_device_ts ON points(device_id, timestamp);
CREATE INDEX IF NOT EXISTS idx_points_ride_id ON points(ride_id);
CREATE INDEX IF NOT EXISTS idx_points_owner ON points(owner_sub);
CREATE INDEX IF NOT EXISTS idx_points_owner_device ON points(owner_sub, device_id);

CREATE INDEX IF NOT EXISTS idx_rides_start_time ON rides(start_time);
CREATE UNIQUE INDEX IF NOT EXISTS idx_rides_trip_id ON rides(trip_id) WHERE trip_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_rides_owner ON rides(owner_sub);

-- Per-user ingest tokens. The Overland-iOS app on each person's phone is
-- configured with their own token; whichever token a batch arrives with
-- determines which account the points/rides get attributed to. There is no
-- shared/global ingest token anymore.
CREATE TABLE IF NOT EXISTS ingest_tokens (
  token TEXT PRIMARY KEY,
  owner_sub TEXT NOT NULL,
  owner_email TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_ingest_tokens_owner ON ingest_tokens(owner_sub);

-- OpenStreetMap features (traffic signals, stop / give-way signs, level crossings) near the places a rider stood still, cached per 0.05 degree
-- tile (about 4 x 5.5 km) so the public Overpass API is asked once per tile and not once per ride. See app/osm.py.
CREATE TABLE IF NOT EXISTS osm_tiles (
  tile_id TEXT PRIMARY KEY,
  fetched_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS osm_features (
  osm_id INTEGER NOT NULL,
  kind TEXT NOT NULL,                      -- traffic_light | stop_sign | give_way | rail_crossing
  lat REAL NOT NULL,
  lon REAL NOT NULL,
  direction TEXT,
  tile_id TEXT NOT NULL,
  PRIMARY KEY (osm_id, kind)
);
CREATE INDEX IF NOT EXISTS idx_osm_features_tile ON osm_features(tile_id);
CREATE INDEX IF NOT EXISTS idx_osm_features_pos ON osm_features(lat, lon);

-- Garage (see app/garage.py and app/garage_store.py). A ride counts towards a bike's odometer when rides.bike_id is that bike, or when it is NULL and
-- the bike is the owner's default, and in both cases only from the bike's start_date on (rides before the bike was added are not on its odometer).
CREATE TABLE IF NOT EXISTS bikes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  owner_sub TEXT NOT NULL,
  name TEXT NOT NULL,
  make TEXT NOT NULL DEFAULT '',
  model TEXT NOT NULL DEFAULT '',
  year INTEGER,
  start_odometer_km REAL NOT NULL DEFAULT 0,      -- what the odometer read on start_date
  start_date TEXT NOT NULL,                        -- YYYY-MM-DD
  is_default INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_bikes_owner ON bikes(owner_sub);

CREATE TABLE IF NOT EXISTS service_items (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  bike_id INTEGER NOT NULL,
  owner_sub TEXT NOT NULL,
  name TEXT NOT NULL,
  interval_km REAL,
  interval_months INTEGER,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_service_items_bike ON service_items(bike_id);

CREATE TABLE IF NOT EXISTS service_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  item_id INTEGER NOT NULL,
  bike_id INTEGER NOT NULL,
  owner_sub TEXT NOT NULL,
  done_date TEXT NOT NULL,
  odometer_km REAL,
  cost REAL,
  note TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_service_log_item ON service_log(item_id);
CREATE INDEX IF NOT EXISTS idx_service_log_bike ON service_log(bike_id);

CREATE TABLE IF NOT EXISTS fuel_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  bike_id INTEGER NOT NULL,
  owner_sub TEXT NOT NULL,
  date TEXT NOT NULL,
  odometer_km REAL NOT NULL,
  litres REAL NOT NULL,
  price REAL,                                      -- the total paid
  full_tank INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_fuel_log_bike ON fuel_log(bike_id);

CREATE TABLE IF NOT EXISTS expenses (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  bike_id INTEGER NOT NULL,
  owner_sub TEXT NOT NULL,
  date TEXT NOT NULL,
  category TEXT NOT NULL DEFAULT '',
  amount REAL NOT NULL,
  note TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_expenses_bike ON expenses(bike_id);

-- Slow or remote answers about one ride (kind: match = road and limit per point from Valhalla, weather = Open-Meteo hours). `points` is the number of
-- prepared points the answer was made for, so a ride that grew (late uploads) is looked up again; `version` lets a changed format invalidate old rows.
CREATE TABLE IF NOT EXISTS ride_extras (
  ride_id INTEGER NOT NULL,
  kind TEXT NOT NULL,
  version INTEGER NOT NULL,
  points INTEGER NOT NULL,
  payload TEXT NOT NULL,
  fetched_at TEXT NOT NULL,
  PRIMARY KEY (ride_id, kind)
);

-- Which OpenStreetMap roads a ride went along: the matched points of the ride, thinned to one about every 40 m per road. It is what the Roads layer uses to
-- say "ridden / not ridden yet". Filled when a ride is matched (opening its insights, or the background catch-up in routes/api_roads.py).
CREATE TABLE IF NOT EXISTS ride_ways (
  ride_id INTEGER NOT NULL,
  way_id INTEGER NOT NULL,
  lat REAL NOT NULL,
  lon REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_ride_ways_way ON ride_ways(way_id);
CREATE INDEX IF NOT EXISTS idx_ride_ways_ride ON ride_ways(ride_id);

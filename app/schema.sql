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

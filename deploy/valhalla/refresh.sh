#!/bin/sh
# Rebuilds Valhalla with a fresh Switzerland map, then the twisty-road database from it. Run it by hand or from the systemd timer once a month; the map matcher
# is down while tiles are rebuilt (rides still open, the limits panel says the map service is not answering).
set -eu
cd "$(dirname "$0")"
DATA="${VALHALLA_DATA:-/home/skysurfer1508/valhalla-data}"
docker compose down
rm -f "$DATA"/*.osm.pbf                    # the container downloads the newest one when it is missing
FORCE_REBUILD=True docker compose up -d

# The container downloads the new map first thing. Once that file stops growing, rebuild the twisty-road database (Roads layer) from the same map. If this
# step fails the old roads.db stays in place (it is only replaced at the very end), so the app keeps working.
PBF="$DATA/switzerland-latest.osm.pbf"
waited=0
while [ ! -s "$PBF" ] && [ "$waited" -lt 120 ]; do sleep 5; waited=$((waited + 1)); done
previous=-1
while :; do
  size=$(stat -c %s "$PBF" 2>/dev/null || echo 0)
  [ "$size" = "$previous" ] && [ "$size" != 0 ] && break
  previous=$size
  sleep 20
done
cd ../..
.venv/bin/python -m app.cli build-roads --pbf "$PBF" || echo "The road database was not rebuilt (the old one is still in use)."

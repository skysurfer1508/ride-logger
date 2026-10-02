#!/bin/sh
# Rebuilds Valhalla with a fresh Switzerland map. Run it by hand or from the systemd timer once a month; the service is down while tiles are rebuilt.
set -eu
cd "$(dirname "$0")"
DATA="${VALHALLA_DATA:-/home/skysurfer1508/valhalla-data}"
docker compose down
rm -f "$DATA"/*.osm.pbf                    # the container downloads the newest one when it is missing
FORCE_REBUILD=True docker compose up -d

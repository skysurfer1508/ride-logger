"""The Swiss TMC (AlertC) location table: turns the location codes the official traffic feed uses into coordinates.

Most records in the Swiss traffic situations feed (about 96 % of them when this was written) have NO coordinates, only AlertC codes such as
country 4, table 9, location 11187. The table that says where each code is comes from opentransportdata.swiss ("TMC Location Codes", open data,
ASTRA terms). It is downloaded once into the data folder (never committed to git) and kept in memory. The feed names the table version it
uses; codes are only resolved when that matches TABLE_VERSION, because a different version can reuse a code for another place.
"""
import csv
import io
import logging
import threading
import time
import zipfile
from pathlib import Path
from typing import Optional

import httpx

from .config import settings

logger = logging.getLogger("ride_logger.tmc")

BASE = "https://data.opentransportdata.swiss/de/dataset/70c603be-92c8-4581-bab7-d97ab06bb490/resource/"
# The feed mixes table versions (7.5 for most records, 7.4 and 7.3 for the rest) and a code can mean a different place in another version, so each
# record is looked up in the table of ITS version. All three are published as open data.
TABLES = {
    "7.3": BASE + "37812015-c6dc-4c57-9417-20db15e703aa/download/tmc_location_codes_v7-3.zip",
    "7.4": BASE + "4344eb97-060d-4199-82c5-aa68912428f4/download/tmc_location_codes_v7-4.zip",
    "7.5": BASE + "b1fb7993-6e2b-4825-b386-4e32d79405c1/download/tmc_location_codes_v7-5.zip",
}
RETRY_AFTER_FAILURE_S = 600
MAX_ZIP_BYTES = 20 * 1024 * 1024        # the real files are 1.2 MB: anything huge is not them

_lock = threading.Lock()
_tables: dict[str, dict[str, tuple[float, float]]] = {}
_failed_at: dict[str, float] = {}


def table_path(version: str) -> Path:
    return Path(settings.db_path).parent / f"tmc_locations_{version}.zip"


def parse_points(data: bytes) -> dict[str, tuple[float, float]]:
    """{location code: (lat, lon)} from the table's ZIP. Coordinates are stored in 1/100000 degree, e.g. XCOORD +00612956 = 6.12956."""
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        name = next((n for n in z.namelist() if n.upper().endswith("POINTS.DAT")), None)
        if name is None:
            raise ValueError("no POINTS.DAT in the TMC table")
        text = z.read(name).decode("utf-8-sig")
    points: dict[str, tuple[float, float]] = {}
    for row in csv.DictReader(io.StringIO(text), delimiter=";"):
        try:
            lat, lon = int(row["YCOORD"]) / 1e5, int(row["XCOORD"]) / 1e5
        except (KeyError, ValueError, TypeError):
            continue
        if 40 < lat < 50 and 4 < lon < 12:           # Switzerland and its surroundings: anything else is a broken row
            points[row["LCD"].strip()] = (lat, lon)
    if not points:
        raise ValueError("the TMC table had no usable points")
    return points


def _download(version: str) -> bytes:
    response = httpx.get(TABLES[version], timeout=60.0, follow_redirects=True, headers={"User-Agent": settings.osm_user_agent})
    if response.status_code != 200 or len(response.content) > MAX_ZIP_BYTES:
        raise RuntimeError(f"HTTP {response.status_code}")
    return response.content


def _load(version: str) -> Optional[dict[str, tuple[float, float]]]:
    if version in _tables:
        return _tables[version]
    if version not in TABLES:
        return None
    failed = _failed_at.get(version)
    if failed is not None and time.monotonic() - failed < RETRY_AFTER_FAILURE_S:
        return None
    path = table_path(version)
    try:
        data = path.read_bytes() if path.exists() else _download(version)
        points = parse_points(data)
        if not path.exists():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
    except Exception as e:
        logger.warning("TMC location table %s unavailable: %s", version, e)
        _failed_at[version] = time.monotonic()
        path.unlink(missing_ok=True)                  # a saved file that cannot be read is removed, so the next try downloads it afresh
        return None
    _tables[version] = points
    logger.info("TMC location table %s loaded: %d points", version, len(points))
    return points


def locations() -> dict[str, dict[str, tuple[float, float]]]:
    """{table version: {location code: (lat, lon)}} for every table that could be loaded (from disk, or downloaded once and saved). A table that
    cannot be had is left out: incidents that only have its codes are counted as 'no map position'. A failed download is not retried for ten minutes."""
    with _lock:
        for version in TABLES:
            _load(version)
        return dict(_tables)


def forget() -> None:
    """For tests: drop the in-memory tables and the failure memory."""
    with _lock:
        _tables.clear()
        _failed_at.clear()

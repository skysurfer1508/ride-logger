"""Builds roads.db from an OpenStreetMap extract (a .osm.pbf, or a small .osm for tests). Run it with `python -m app.cli build-roads --pbf FILE`.

Needs the `osmium` package (pip install osmium); the web server does not. Switzerland takes a few minutes and a few GB of memory. The new database is built
next to the old one and moved into place at the end, so the app keeps working while it runs.
"""
import os
import sys
from pathlib import Path
from typing import Optional

from . import curvature, roads


def build(pbf: Path, target: Optional[Path] = None, progress=print) -> int:
    try:
        import osmium
    except ImportError:
        raise SystemExit("The `osmium` package is needed to build the road database: pip install osmium")
    target = target or roads.path()
    temp = target.with_name(target.name + ".building")
    conn = roads.create(temp)
    stats = {"ways": 0, "kept": 0, "segments": 0}

    class Handler(osmium.SimpleHandler):
        def way(self, w):
            stats["ways"] += 1
            if stats["ways"] % 200_000 == 0:
                progress(f"  {stats['ways']:,} ways read, {stats['segments']:,} stretches so far")
            highway = w.tags.get("highway")
            if highway not in curvature.WANTED_HIGHWAYS:
                return
            tags = {k: v for k, v in ((t.k, t.v) for t in w.tags)}
            if not curvature.wanted(tags):
                return
            try:
                coords = [(n.lat, n.lon) for n in w.nodes if n.location.valid()]
            except osmium.InvalidLocationError:
                return
            if len(coords) < 2:
                return
            stored = roads.add_way(conn, w.id, tags, coords)
            if stored:
                stats["kept"] += 1
                stats["segments"] += stored

    progress(f"Reading {pbf} ...")
    Handler().apply_file(str(pbf), locations=True, idx="flex_mem")
    count = roads.finish(conn, source=pbf.name)
    os.replace(temp, target)
    progress(f"Done: {count:,} stretches from {stats['kept']:,} roads ({stats['ways']:,} ways read) -> {target}")
    return count

"""app/tmc.py: the Swiss AlertC location tables. The ZIPs here are tiny and built in the layout of the real files (POINTS.DAT, semicolon separated,
a byte-order mark, coordinates in 1/100000 degree with a sign), which was checked against the real 7.3 file."""
import io
import zipfile

import pytest

from app import tmc
from app.config import settings

HEADER = "CID;TABCD;LCD;CLASS;TCD;STCD;JUNCTIONNUMBER;RNID;N1ID;N2ID;POL_LCD;OTH_LCD;SEG_LCD;ROA_LCD;INPOS;INNEG;OUTPOS;OUTNEG;PRESENTPOS;PRESENTNEG;DIVERSIONPOS;DIVERSIONNEG;XCOORD;YCOORD;INTERRUPTSROAD;URBAN;JNID"


def row(lcd, x, y):
    return f"51;9;{lcd};P;1;11;;499621;498742;;34753;;;30865;1;1;1;1;1;1;;;{x};{y};;0;"


def make_zip(rows, name="CH_104_E1_4_9_7.3_LTEF/POINTS.DAT"):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr(name, "﻿" + "\n".join([HEADER, *rows]))
    return buf.getvalue()


GOOD = make_zip([row(30866, "+00612956", "+4621373"), row(27306, "+00813881", "+4748090")])


@pytest.fixture(autouse=True)
def data_dir(tmp_path, monkeypatch):
    monkeypatch.setattr(settings, "db_path", str(tmp_path / "ride.db"))
    tmc.forget()


def test_points_are_read_with_the_real_coordinate_encoding():
    points = tmc.parse_points(GOOD)
    assert points["30866"] == (46.21373, 6.12956)                          # Geneva area: +4621373 is latitude 46.21373, +00612956 is longitude 6.12956
    assert points["27306"] == (47.4809, 8.13881)


def test_broken_rows_are_skipped_and_nonsense_coordinates_too():
    data = make_zip([row(1, "+00612956", "+4621373"), row(2, "garbage", "+4621373"), row(3, "+00000000", "+0000000"), row(4, "+09999999", "+9999999")])
    assert set(tmc.parse_points(data)) == {"1"}


def test_a_zip_without_points_is_an_error():
    with pytest.raises(ValueError):
        tmc.parse_points(make_zip([], name="other.txt"))
    with pytest.raises(ValueError):
        tmc.parse_points(make_zip([row(3, "+00000000", "+0000000")]))        # only unusable rows
    with pytest.raises(Exception):
        tmc.parse_points(b"not a zip")


def test_a_table_is_downloaded_once_saved_and_then_read_from_disk(monkeypatch):
    calls = []
    monkeypatch.setattr(tmc, "_download", lambda version: calls.append(version) or GOOD)
    first = tmc.locations()
    assert set(first) == {"7.3", "7.4", "7.5"} and first["7.5"]["30866"] == (46.21373, 6.12956)
    assert sorted(calls) == ["7.3", "7.4", "7.5"]
    assert tmc.table_path("7.5").exists()
    tmc.forget()
    monkeypatch.setattr(tmc, "_download", lambda version: pytest.fail("should read the saved file"))
    assert tmc.locations()["7.4"]["27306"] == (47.4809, 8.13881)


def test_a_failed_download_gives_what_is_available_and_waits_before_trying_again(monkeypatch):
    calls = []
    def flaky(version):
        calls.append(version)
        if version == "7.4":
            raise RuntimeError("HTTP 503")
        return GOOD
    monkeypatch.setattr(tmc, "_download", flaky)
    assert set(tmc.locations()) == {"7.3", "7.5"}                          # the other tables still work
    n = len(calls)
    tmc.locations()
    assert calls[n:] == []                                                 # not asked again for ten minutes
    assert not tmc.table_path("7.4").exists()


def test_a_broken_download_is_not_saved(monkeypatch):
    monkeypatch.setattr(tmc, "_download", lambda version: b"<html>captive portal</html>")
    assert tmc.locations() == {}
    assert not any(tmc.table_path(v).exists() for v in tmc.TABLES)


def test_a_corrupt_saved_file_is_not_trusted(monkeypatch):
    tmc.table_path("7.5").write_bytes(b"truncated")
    monkeypatch.setattr(tmc, "_download", lambda version: GOOD)
    assert "7.5" not in tmc.locations()                                    # reported as unavailable, not a crash; the other versions load
    assert not tmc.table_path("7.5").exists()                              # removed, so that the next try (after the pause) downloads a good copy
    tmc.forget()
    assert "7.5" in tmc.locations()


def test_every_known_version_has_a_download_address():
    assert set(tmc.TABLES) == {"7.3", "7.4", "7.5"}
    assert all(url.startswith("https://data.opentransportdata.swiss/") and url.endswith(".zip") for url in tmc.TABLES.values())

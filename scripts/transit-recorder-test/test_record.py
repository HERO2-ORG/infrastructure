import gzip
import sys
from pathlib import Path

import pyarrow.parquet as pq
from google.transit import gtfs_realtime_pb2

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "ansible/roles/transit-recorder/files"))
import compact_vehicle_positions as compact  # noqa: E402
import record_vehicle_positions as rec  # noqa: E402


def _feed():
    f = gtfs_realtime_pb2.FeedMessage()
    f.header.gtfs_realtime_version = "2.0"
    f.header.timestamp = 1792000000
    e = f.entity.add()
    e.id = "1"
    v = e.vehicle
    v.vehicle.id = "bus-7"
    v.trip.trip_id = "AC:123"
    v.trip.route_id = "51B"
    v.position.latitude = 37.87
    v.position.longitude = -122.26
    v.position.bearing = 90
    v.position.speed = 8.0
    v.timestamp = 1791999990
    return f.SerializeToString()


def test_feed_becomes_rows():
    rows = rec.rows_from_feed(_feed())
    assert rows == [{"feed_ts": 1792000000, "vehicle_ts": 1791999990, "vehicle_id": "bus-7", "trip_id": "AC:123",
                     "route_id": "51B", "agency": "AC", "lat": 37.87, "lon": -122.26, "bearing": 90.0, "speed": 8.0}]


def test_gzipped_body_is_decoded():
    assert rec.decode_body(gzip.compress(_feed())) == _feed()
    assert rec.decode_body(_feed()) == _feed()


def test_snapshot_is_written_and_metric_updated(tmp_path):
    rec.write_snapshot(rec.rows_from_feed(_feed()), tmp_path / "store", tmp_path / "metrics", now=1792000000)
    files = list((tmp_path / "store").rglob("snap-*.parquet"))
    assert len(files) == 1 and "dt=2026-10-14" in str(files[0])
    prom = (tmp_path / "metrics" / "hero2_transit.prom").read_text()
    assert "hero2_transit_rt_last_rows 1" in prom
    assert "hero2_transit_rt_last_success_timestamp_seconds 1792000000" in prom


def _snap(store, day, epoch, n):
    rows = [dict(r, vehicle_id=f"v{epoch}-{i}") for i, r in enumerate(rec.rows_from_feed(_feed()) * n)]
    d = store / f"dt={day}"
    d.mkdir(parents=True, exist_ok=True)
    rec.write_parquet(rows, d / f"snap-{epoch}.parquet")


def test_compaction_merges_past_days_and_spares_today(tmp_path):
    store = tmp_path / "store"
    _snap(store, "2026-10-12", 1, 2)
    _snap(store, "2026-10-12", 2, 3)
    _snap(store, "2026-10-14", 3, 4)
    compact.compact_store(store, today="2026-10-14")
    day = store / "dt=2026-10-12"
    assert pq.read_table(day / "day.parquet").num_rows == 5
    assert not list(day.glob("snap-*.parquet"))
    assert len(list((store / "dt=2026-10-14").glob("snap-*.parquet"))) == 1


def test_snapshots_survive_when_day_file_is_short(tmp_path, monkeypatch):
    store = tmp_path / "store"
    _snap(store, "2026-10-12", 1, 2)
    monkeypatch.setattr(compact, "count_rows", lambda path: 0)
    compact.compact_store(store, today="2026-10-14")
    assert len(list((store / "dt=2026-10-12").glob("snap-*.parquet"))) == 1

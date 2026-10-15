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


def _day_rows(store, day):
    return pq.read_table(store / f"dt={day}" / "day.parquet").to_pylist()


def test_existing_day_file_is_extended_not_replaced(tmp_path):
    store = tmp_path / "store"
    _snap(store, "2026-10-12", 1, 2)
    compact.compact_store(store, today="2026-10-14")
    _snap(store, "2026-10-12", 2, 3)
    compact.compact_store(store, today="2026-10-14")
    assert len(_day_rows(store, "2026-10-12")) == 5
    assert not list((store / "dt=2026-10-12").glob("snap-*.parquet"))


def test_rerun_after_partial_deletion_loses_and_duplicates_nothing(tmp_path):
    store = tmp_path / "store"
    _snap(store, "2026-10-12", 1, 2)
    _snap(store, "2026-10-12", 2, 3)
    survivor = store / "dt=2026-10-12" / "snap-2.parquet"
    saved = survivor.read_bytes()
    compact.compact_store(store, today="2026-10-14")
    survivor.write_bytes(saved)
    compact.compact_store(store, today="2026-10-14")
    assert len(_day_rows(store, "2026-10-12")) == 5
    assert not survivor.exists()


def test_failed_verification_leaves_existing_day_file_intact(tmp_path, monkeypatch):
    store = tmp_path / "store"
    _snap(store, "2026-10-12", 1, 2)
    compact.compact_store(store, today="2026-10-14")
    before = (store / "dt=2026-10-12" / "day.parquet").read_bytes()
    _snap(store, "2026-10-12", 2, 3)
    monkeypatch.setattr(compact, "count_rows", lambda path: 0)
    compact.compact_store(store, today="2026-10-14")
    assert (store / "dt=2026-10-12" / "day.parquet").read_bytes() == before
    assert len(list((store / "dt=2026-10-12").glob("snap-*.parquet"))) == 1


def test_compaction_metrics_on_success_and_failure(tmp_path, monkeypatch):
    store, metrics = tmp_path / "store", tmp_path / "metrics"
    _snap(store, "2026-10-12", 1, 2)
    assert compact.run(store, metrics, now=1791936000 + 100)
    prom = (metrics / "hero2_transit_compact.prom").read_text()
    assert "hero2_transit_compact_last_success_timestamp_seconds 1791936100" in prom
    assert "hero2_transit_uncompacted_snapshots 0" in prom
    _snap(store, "2026-10-12", 2, 1)
    monkeypatch.setattr(compact, "count_rows", lambda path: 0)
    assert not compact.run(store, metrics, now=1791936000 + 500)
    prom = (metrics / "hero2_transit_compact.prom").read_text()
    assert "hero2_transit_compact_last_success_timestamp_seconds 1791936100" in prom
    assert "hero2_transit_uncompacted_snapshots 1" in prom


def _setup_main(tmp_path, monkeypatch, get):
    monkeypatch.setenv("TRANSIT_511_API_TOKEN", "t")
    monkeypatch.setattr(rec, "STORE", tmp_path / "store")
    monkeypatch.setattr(rec, "METRICS", tmp_path / "metrics")
    monkeypatch.setattr(rec.requests, "get", get)
    metrics = tmp_path / "metrics" / "hero2_transit.prom"
    metrics.parent.mkdir()
    metrics.write_text("old\n")
    return metrics


class _Resp:
    def __init__(self, content=b"", error=None):
        self.content, self.error = content, error

    def raise_for_status(self):
        if self.error:
            raise self.error


def _run_main(monkeypatch):
    import pytest
    monkeypatch.setattr(sys, "argv", ["x"])
    with pytest.raises(SystemExit) as e:
        rec.run_cli()
    return e.value.code


def test_http_error_exits_1_and_keeps_metrics(tmp_path, monkeypatch):
    metrics = _setup_main(tmp_path, monkeypatch, lambda *a, **k: _Resp(error=rec.requests.HTTPError("503")))
    assert _run_main(monkeypatch) == 1
    assert metrics.read_text() == "old\n"


def test_undecodable_body_exits_1_and_keeps_metrics(tmp_path, monkeypatch):
    metrics = _setup_main(tmp_path, monkeypatch, lambda *a, **k: _Resp(b"\xff\xfe not a feed"))
    assert _run_main(monkeypatch) == 1
    assert metrics.read_text() == "old\n"


def test_empty_feed_exits_1_and_keeps_metrics(tmp_path, monkeypatch):
    f = gtfs_realtime_pb2.FeedMessage()
    f.header.gtfs_realtime_version = "2.0"
    f.header.timestamp = 1792000000
    metrics = _setup_main(tmp_path, monkeypatch, lambda *a, **k: _Resp(f.SerializeToString()))
    assert _run_main(monkeypatch) == 1
    assert metrics.read_text() == "old\n"
    assert not list((tmp_path / "store").rglob("snap-*")) if (tmp_path / "store").exists() else True


def test_good_feed_exits_0(tmp_path, monkeypatch):
    metrics = _setup_main(tmp_path, monkeypatch, lambda *a, **k: _Resp(_feed()))
    assert _run_main(monkeypatch) == 0
    assert "hero2_transit_rt_last_rows 1" in metrics.read_text()


def test_utc_day_boundary(tmp_path):
    rows = rec.rows_from_feed(_feed())
    rec.write_snapshot(rows, tmp_path / "s", tmp_path / "m", now=1791935999)
    rec.write_snapshot(rows, tmp_path / "s", tmp_path / "m", now=1791936000)
    assert (tmp_path / "s/dt=2026-10-13/snap-1791935999.parquet").exists()
    assert (tmp_path / "s/dt=2026-10-14/snap-1791936000.parquet").exists()


def _agency(trip_id, route_id, vehicle_id):
    f = gtfs_realtime_pb2.FeedMessage()
    f.header.gtfs_realtime_version = "2.0"
    f.header.timestamp = 1
    e = f.entity.add()
    e.id = "1"
    v = e.vehicle
    v.trip.trip_id, v.trip.route_id, v.vehicle.id = trip_id, route_id, vehicle_id
    return rec.rows_from_feed(f.SerializeToString())[0]["agency"]


def test_agency_falls_back_from_trip_to_route_to_vehicle():
    assert _agency("AC:1", "SF:9", "GG:3") == "AC"
    assert _agency("123", "SF:9", "GG:3") == "SF"
    assert _agency("123", "9", "GG:3") == "GG"
    assert _agency("123", "9", "3") == ""

#!/usr/bin/env python3
import gzip
import os
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq
import requests
from google.transit import gtfs_realtime_pb2

URL = "https://api.511.org/transit/vehiclepositions"
STORE = Path("/srv/data/transit/vehicle_positions")
METRICS = Path("/var/lib/node-exporter")

SCHEMA = pa.schema([
    ("fetched_ts", pa.int64()), ("feed_ts", pa.int64()), ("vehicle_ts", pa.int64()), ("vehicle_id", pa.string()),
    ("trip_id", pa.string()), ("route_id", pa.string()), ("agency", pa.string()),
    ("lat", pa.float64()), ("lon", pa.float64()), ("bearing", pa.float64()), ("speed", pa.float64()),
])


def decode_body(body):
    return gzip.decompress(body) if body[:2] == b"\x1f\x8b" else body


def agency_of(*identifiers):
    for identifier in identifiers:
        if ":" in identifier:
            return identifier.split(":", 1)[0]
    return ""


def present(message, field, convert=lambda value: value):
    return convert(getattr(message, field)) if message.HasField(field) else None


def rows_from_feed(body):
    feed = gtfs_realtime_pb2.FeedMessage()
    feed.ParseFromString(body)
    rows = []
    for entity in feed.entity:
        if not (entity.HasField("vehicle") and entity.vehicle.HasField("position")):
            continue
        v = entity.vehicle
        trip_id = present(v.trip, "trip_id")
        route_id = present(v.trip, "route_id")
        vehicle_id = present(v.vehicle, "id")
        rows.append({
            "feed_ts": present(feed.header, "timestamp"),
            "vehicle_ts": present(v, "timestamp"),
            "vehicle_id": vehicle_id,
            "trip_id": trip_id,
            "route_id": route_id,
            "agency": agency_of(trip_id or "", route_id or "", vehicle_id or ""),
            "lat": round(v.position.latitude, 5),
            "lon": round(v.position.longitude, 5),
            "bearing": present(v.position, "bearing", lambda x: round(x, 6)),
            "speed": present(v.position, "speed", lambda x: round(x, 6)),
        })
    return rows


def atomic_write(path, write):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    os.close(fd)
    try:
        write(tmp)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


def write_parquet(rows, path):
    table = pa.Table.from_pylist(rows, schema=SCHEMA)
    atomic_write(path, lambda tmp: pq.write_table(table, tmp, compression="zstd"))


def write_snapshot(rows, store, metrics_dir, now):
    day = datetime.fromtimestamp(now, timezone.utc).strftime("%Y-%m-%d")
    write_parquet([dict(row, fetched_ts=now) for row in rows], Path(store) / f"dt={day}" / f"snap-{now}.parquet")
    text = (
        f"hero2_transit_rt_last_success_timestamp_seconds {now}\n"
        f"hero2_transit_rt_last_rows {len(rows)}\n"
    )
    atomic_write(Path(metrics_dir) / "hero2_transit.prom", lambda tmp: Path(tmp).write_text(text))


def main():
    response = requests.get(
        URL, params={"api_key": os.environ["TRANSIT_511_API_TOKEN"], "agency": "RG"}, timeout=30
    )
    response.raise_for_status()
    rows = rows_from_feed(decode_body(response.content))
    if not rows:
        raise ValueError("feed holds no vehicles")
    write_snapshot(rows, STORE, METRICS, int(time.time()))


def run_cli():
    try:
        main()
    except Exception as exc:
        print(f"recording failed: {type(exc).__name__}", file=sys.stderr)
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    run_cli()

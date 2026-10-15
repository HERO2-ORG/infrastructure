#!/usr/bin/env python3
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

from record_vehicle_positions import METRICS, SCHEMA, STORE, atomic_write

SUCCESS_METRIC = "hero2_transit_compact_last_success_timestamp_seconds"


def count_rows(path):
    return pq.read_table(path).num_rows


def compact_day(day_dir):
    snaps = sorted(day_dir.glob("snap-*.parquet"))
    if not snaps:
        return
    day_file = day_dir / "day.parquet"
    tables = []
    if day_file.exists():
        existing = pq.read_table(day_file, schema=SCHEMA)
        tables.append(existing)
        columns = SCHEMA.names
        for s in snaps:
            tables.append(pq.read_table(s, schema=SCHEMA).join(existing, keys=columns, join_type="left anti"))
    else:
        tables = [pq.read_table(s, schema=SCHEMA) for s in snaps]
    merged = pa.concat_tables(tables)

    def write(tmp):
        pq.write_table(merged, tmp, compression="zstd")
        if count_rows(tmp) != merged.num_rows:
            raise RuntimeError(f"{day_file} would hold fewer rows than expected; snapshots kept")

    atomic_write(day_file, write)
    for s in snaps:
        s.unlink()


def past_days(store, today):
    return [d for d in sorted(Path(store).glob("dt=*")) if d.name[3:] < today]


def compact_store(store, today):
    ok = True
    for day_dir in past_days(store, today):
        try:
            compact_day(day_dir)
        except Exception as exc:
            ok = False
            print(f"{day_dir.name}: {exc}", file=sys.stderr)
    return ok


def previous_success(metrics_file):
    if not metrics_file.exists():
        return None
    for line in metrics_file.read_text().splitlines():
        if line.startswith(SUCCESS_METRIC):
            return int(line.split()[1])
    return None


def run(store, metrics_dir, now):
    today = datetime.fromtimestamp(now, timezone.utc).strftime("%Y-%m-%d")
    metrics_file = Path(metrics_dir) / "hero2_transit_compact.prom"
    last_success = previous_success(metrics_file)
    ok = compact_store(store, today)
    if ok:
        last_success = now
    pending = sum(len(list(d.glob("snap-*.parquet"))) for d in past_days(store, today))
    lines = [f"hero2_transit_uncompacted_snapshots {pending}\n"]
    if last_success is not None:
        lines.insert(0, f"{SUCCESS_METRIC} {last_success}\n")
    atomic_write(metrics_file, lambda tmp: Path(tmp).write_text("".join(lines)))
    return ok


if __name__ == "__main__":
    sys.exit(0 if run(STORE, METRICS, int(time.time())) else 1)

#!/usr/bin/env python3
import sys
from datetime import datetime, timezone
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

from record_vehicle_positions import SCHEMA, STORE, atomic_write


def count_rows(path):
    return pq.ParquetFile(path).metadata.num_rows


def compact_day(day_dir):
    snaps = sorted(day_dir.glob("snap-*.parquet"))
    if not snaps:
        return
    table = pa.concat_tables([pq.read_table(s, schema=SCHEMA) for s in snaps])
    day_file = day_dir / "day.parquet"
    atomic_write(day_file, lambda tmp: pq.write_table(table, tmp, compression="zstd"))
    if count_rows(day_file) != table.num_rows:
        raise RuntimeError(f"{day_file} holds fewer rows than its snapshots; snapshots kept")
    for s in snaps:
        s.unlink()


def compact_store(store, today):
    failed = False
    for day_dir in sorted(Path(store).glob("dt=*")):
        if day_dir.name[3:] >= today:
            continue
        try:
            compact_day(day_dir)
        except Exception as exc:
            failed = True
            print(f"{day_dir.name}: {exc}", file=sys.stderr)
    return not failed


if __name__ == "__main__":
    sys.exit(0 if compact_store(STORE, datetime.now(timezone.utc).strftime("%Y-%m-%d")) else 1)

# M004 — Disk Activity Ranking & Interval Aggregation

## Status: COMPLETE

## Goal

Turn the raw `disk_process_events` rows into ranked, per-interval process-level
disk activity metrics, answering:

> "Which processes generated the most disk activity during this monitoring interval?"

---

## Scope

- **In scope**: `Database.swift`, `mac_detective.swift`, test suite
- **Out of scope**: new persistent aggregation tables, redesigning the architecture,
  process rusage, unrelated collectors

---

## New Types

### `DiskProcessSummary` (Database.swift)

```swift
struct DiskProcessSummary: Sendable, Equatable {
    let processName: String
    let pid:         Int32
    let readBytes:   UInt64   // SUM of bytes where UPPER(operation) LIKE 'R%'
    let writeBytes:  UInt64   // SUM of bytes where UPPER(operation) LIKE 'W%'
    let totalBytes:  UInt64   // SUM of ALL bytes (may exceed readBytes+writeBytes for PgOut etc.)
}
```

---

## New API

### `Database.getTopDiskProcesses(snapshotID:limit:) -> [DiskProcessSummary]`

SQL aggregation over `disk_process_events`:

```sql
SELECT
    process_name,
    pid,
    COALESCE(SUM(CASE WHEN UPPER(operation) LIKE 'R%' THEN bytes ELSE 0 END), 0) AS read_bytes,
    COALESCE(SUM(CASE WHEN UPPER(operation) LIKE 'W%' THEN bytes ELSE 0 END), 0) AS write_bytes,
    COALESCE(SUM(bytes), 0) AS total_bytes
FROM disk_process_events
[WHERE snapshot_id = ?]
GROUP BY process_name, pid
ORDER BY total_bytes DESC, process_name ASC, pid ASC
LIMIT ?;
```

Parameters:
- `snapshotID: Int64? = nil` — when provided, filters to that snapshot's events only
- `limit: Int = 5` — caps results

The `R%` / `W%` prefix pattern handles:
- `R`, `Read`, `RdMeta` → counted as reads
- `W`, `Write`, `WrMeta` → counted as writes
- `PgOut`, `PgIn`, `ReName`, etc. — counted in `totalBytes` but not in either bucket

---

## Console Output (mac_detective.swift)

After each snapshot interval, the top 3 disk processes by snapshot are printed:

```
💾 Disk activity (fs_usage):
   Chrome [1234]  ↓ 18.40 MB  ↑ 2.10 MB
   Code   [5678]  ↓ 7.20 MB   ↑ 0.80 MB
```

Gated on `!topDiskProcesses.isEmpty` — no output when fs_usage produced no events.

---

## Tests Added (mac_detectiveTests.swift)

Suite: `Disk Activity Ranking Tests` — 8 tests:

| Test | Verifies |
|------|----------|
| testEmptyRanking | Empty table → empty result |
| testSameProcessAggregation | Multiple events for same process aggregated correctly |
| testReadBytesSum | Pure-read events sum into readBytes |
| testWriteBytesSum | Pure-write events sum into writeBytes |
| testOperationPrefixMatching | Read, Write, RdMeta, WrMeta, PgOut classified correctly |
| testRankingOrder | Results ordered by total_bytes DESC |
| testLimitParameter | limit: caps results |
| testSnapshotIDFiltering | Per-snapshot filter isolates correctly |
| testTotalBytesInvariant | totalBytes = all bytes including non-R/W ops |

---

## Verification

```
swift build --package-path apps/mac-detective   # ✅
swift test  --package-path apps/mac-detective   # ✅ 22 tests, 4 suites
```

---

## Architecture Decision: No Second Aggregation Table

Raw events are kept in `disk_process_events`. Aggregation is computed on-the-fly
via SQL at query time. A pre-computed `disk_interval_summary` table is deferred
to a future mission if query latency becomes a concern.

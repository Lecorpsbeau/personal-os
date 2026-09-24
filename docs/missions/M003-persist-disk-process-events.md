# M003 — Persist DiskProcessEvents to SQLite

Status: DONE

## Phase

Phase 1 — Mac Detective

## Objective

Persist structured filesystem process events (`DiskProcessEvent`) to SQLite so that Personal OS can record, analyze, and query process-level disk activity.

## Architectural Data Flow

```text
fs_usage (process stdout)
    ↓
FSUsageCollector (asynchronous Pipe & thread-safe ring buffer)
    ↓
mac_detective.swift (drainEvents() in 2-second sampling loop)
    ↓
Database.saveDiskProcessEvents(_:snapshotID:)
    ↓
SQLite table: disk_process_events (transactional batch insert)
```

## SQLite Schema

```sql
CREATE TABLE IF NOT EXISTS disk_process_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    snapshot_id INTEGER,
    timestamp REAL NOT NULL,
    operation TEXT NOT NULL,
    bytes INTEGER NOT NULL,
    process_name TEXT NOT NULL,
    pid INTEGER NOT NULL,
    FOREIGN KEY(snapshot_id) REFERENCES system_samples(id)
);

CREATE INDEX IF NOT EXISTS idx_disk_process_events_snapshot_id
ON disk_process_events(snapshot_id);
```

## Database API Added

- `saveDiskProcessEvent(_:snapshotID:) -> Bool`: Inserts a single event.
- `saveDiskProcessEvents(_:snapshotID:) -> Int`: Inserts a batch of events within a single SQLite transaction (`BEGIN TRANSACTION` / `COMMIT`). Safely handles empty batches.
- `getDiskProcessEvents(snapshotID:limit:) -> [DiskProcessEvent]`: Queries persisted disk events filtered optionally by `snapshot_id`.
- `init(databasePath:)`: Optional parameter enabling isolated database paths for unit tests.

## Verification & Acceptance Criteria

- [x] Dedicated `disk_process_events` table and index created.
- [x] Database insertion API implemented for single and batch operations.
- [x] Drained events in `mac_detective.swift` persisted alongside `snapshotID`.
- [x] Bounded and empty event batches handled safely.
- [x] Automated unit tests verify insertion, field integrity (timestamp, operation, bytes, processName, PID), batch processing, snapshot linking, and existing database operations.
- [x] All M001 and M002 tests continue to pass.
- [x] Live vs test persistence distinction documented (root permissions required for live `fs_usage` capture on macOS).

# Active Missions

## M001 — Fix FSUsageParser

Status: DONE

Goal:
Create a safe and testable parser for macOS fs_usage diskio output.

See:
`docs/missions/M001-fix-fsusage-parser.md`

## M002 — Integrate FSUsageCollector

Status: DONE

Goal:
Connect the existing fs_usage pipeline to Mac Detective so that real filesystem activity can be collected as structured DiskProcessEvent values.

See:
`docs/missions/M002-integrate-fsusage-collector.md`

## M003 — Persist DiskProcessEvents to SQLite

Status: DONE

Goal:
Extend the Database layer to persist process-level disk events into SQLite.

See:
`docs/missions/M003-persist-disk-process-events.md`

## M004 — Disk Activity Ranking & Process Aggregation

Status: DONE

Goal:
Aggregate raw disk events by process and interval to identify and rank the top disk I/O consumers.

See:
`docs/missions/M004-disk-activity-ranking.md`

# M002 — Integrate FSUsageCollector

Status: DONE

## Phase

Phase 1 — Mac Detective

## Objective

Connect the existing `fs_usage` pipeline to Mac Detective so that real filesystem activity can be collected as structured `DiskProcessEvent` values.

## Architectural Data Flow

```text
fs_usage (process stdout)
    ↓
FSUsageCollector (asynchronous Pipe & readabilityHandler)
    ↓
FSUsageParser (parse line-by-line)
    ↓
DiskProcessEvent (structured event value)
    ↓
FSUsageCollector (thread-safe bounded in-memory buffer + onEvent callback)
    ↓
Mac Detective (drainEvents() in 2-second monitoring loop)
```

## Investigation Findings

1. **How `FSUsageCollector` exposes events:**
   - Asynchronous events from `fs_usage` are collected into a thread-safe ring buffer (`eventBuffer`) guarded by `NSLock`.
   - Consumers call `drainEvents() -> [DiskProcessEvent]` during their periodic sampling loop to retrieve and clear all events accumulated during that interval.
   - An optional `@Sendable onEvent` callback allows real-time streaming listeners.
   - Input injection via `processOutput(_:)` enables isolated, deterministically testable verification without requiring root execution.

2. **How `mac_detective.swift` receives events:**
   - Instantiates `FSUsageCollector(parser: parser)`.
   - Calls `start()` during initialization.
   - Inside the sampling loop (`sleep(2)`), calls `fsUsageCollector.drainEvents()` alongside `diskCollector.sample()`, `networkCollector.sample()`, and `processCollector.sample()`.
   - Displays real-time disk event counts and volume if events occurred in the current window.

3. **In-memory buffering vs SQLite persistence:**
   - In accordance with constraints, events are kept in-memory in `FSUsageCollector` with a configurable `maxBufferSize` (default 1000) to protect against memory exhaustion.
   - Decoupling buffering from database writes prevents blocking the pipe reader and provides clean batching for future persistence.

4. **Database schema analysis:**
   - Existing tables: `system_samples`, `process_samples`, `events` (anomaly events).
   - Neither `process_samples` nor `events` are designed to store high-frequency `fs_usage` granular disk events (`timestamp, operation, bytes, processName, pid`).
   - A dedicated table (e.g. `disk_process_events` or interval aggregation) is recommended for a dedicated database mission (M003).

## Requirements & Acceptance Criteria

- [x] FSUsageCollector exposes parsed events safely with thread-safe `drainEvents()`.
- [x] mac_detective.swift initializes, starts, and drains `FSUsageCollector`.
- [x] Unit tests added verifying `processOutput`, `drainEvents`, `onEvent`, capacity limits, and error handling.
- [x] All existing `FSUsageParser` unit tests remain intact and passing.
- [x] Zero external dependencies added.
- [x] `swift build` and `swift test` succeed.
- [x] Runtime validation verified.

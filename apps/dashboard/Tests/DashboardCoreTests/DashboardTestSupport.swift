import Foundation
import SQLite3
import Testing
@testable import DashboardCore

final class DashboardDatabaseFixture {
    let directoryURL: URL
    let databaseURL: URL
    let statusURL: URL
    let now: Date

    init(
        schemaVersion: Int = DashboardRepositoryConfiguration.currentSchemaVersion,
        includeRows: Bool = true,
        useWAL: Bool = false
    ) throws {
        now = Date(timeIntervalSince1970: 1_900_000_000)
        directoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dashboard-tests-\(UUID().uuidString)", isDirectory: true)
        databaseURL = directoryURL.appendingPathComponent("mac_detective.sqlite")
        statusURL = directoryURL.appendingPathComponent(
            DashboardRepositoryConfiguration.defaultRuntimeStatusFilename
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        var connection: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &connection) == SQLITE_OK else {
            throw FixtureError.couldNotOpen
        }
        defer { sqlite3_close_v2(connection) }

        if schemaVersion == DashboardRepositoryConfiguration.currentSchemaVersion {
            try execute(schema, on: connection)
        } else {
            try execute(
                "CREATE TABLE system_samples (id INTEGER PRIMARY KEY, timestamp REAL);",
                on: connection
            )
        }
        try execute("PRAGMA user_version = \(schemaVersion);", on: connection)
        if useWAL {
            try execute("PRAGMA journal_mode = WAL;", on: connection)
        }

        if includeRows,
           schemaVersion == DashboardRepositoryConfiguration.currentSchemaVersion {
            try insertRows(on: connection)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func writeRuntimeStatus(
        state: String = "running",
        updatedAt: Date? = nil
    ) throws {
        let payload = RuntimeStatusPayload(
            version: 1,
            state: state,
            updatedAt: updatedAt ?? now,
            cyclesExecuted: 4,
            lastCycleAt: now,
            lastSuccessfulPersistenceAt: now,
            lastMaintenanceAt: now,
            fsUsage: RuntimeFSUsageStatusPayload(
                state: "running",
                diagnostic: nil,
                permissionDenied: false,
                stderr: nil,
                droppedEvents: 2
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(payload).write(to: statusURL, options: [.atomic])
    }

    func makeConfiguration(
        staleAfter: TimeInterval = 10,
        now: Date? = nil
    ) -> DashboardRepositoryConfiguration {
        let referenceDate = now ?? self.now
        return DashboardRepositoryConfiguration(
            databaseURL: databaseURL,
            runtimeStatusURL: statusURL,
            staleAfter: staleAfter,
            now: { referenceDate }
        )
    }

    func insertAdditionalEvents(count: Int) throws {
        var connection: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &connection) == SQLITE_OK else {
            throw FixtureError.couldNotOpen
        }
        defer { sqlite3_close_v2(connection) }
        for index in 0..<count {
            try execute(
                """
                INSERT INTO events
                    (id, snapshot_id, timestamp, type, severity, value, message)
                VALUES (\(index + 4), 3, \(now.timeIntervalSince1970 + Double(index)),
                        'TEST_EVENT', 'info', \(index), 'test');
                """,
                on: connection
            )
        }
    }

    private func insertRows(on connection: OpaquePointer?) throws {
        let snapshotValues = [
            (now.addingTimeInterval(-120), 10.0, 20.0, 1.0, 2.0, 3.0, 4.0, 0),
            (now.addingTimeInterval(-60), 30.0, 40.0, 3.0, 4.0, 5.0, 6.0, 1),
            (now, 50.0, 60.0, 5.0, 6.0, 7.0, 8.0, 2)
        ]
        for (index, value) in snapshotValues.enumerated() {
            try execute(
                """
                INSERT INTO system_samples
                    (id, timestamp, cpu, memory, disk_read, disk_write,
                     network_in, network_out, dropped_events)
                VALUES (\(index + 1), \(value.0.timeIntervalSince1970),
                        \(value.1), \(value.2), \(value.3), \(value.4),
                        \(value.5), \(value.6), \(value.7));
                """,
                on: connection
            )
        }

        try execute(
            """
            INSERT INTO process_samples
                (snapshot_id, timestamp, pid, name, cpu, memory,
                 disk_read_bytes, disk_write_bytes)
            VALUES
                (3, \(now.timeIntervalSince1970), 101, 'alpha', 90.0, 1000, 100, 200),
                (3, \(now.timeIntervalSince1970), 102, 'beta', 20.0, 5000, 300, 400),
                (3, \(now.timeIntervalSince1970), 103, 'gamma', 10.0, 100, 0, 0);
            """,
            on: connection
        )
        try execute(
            """
            INSERT INTO disk_process_events
                (snapshot_id, timestamp, operation, bytes, process_name, pid)
            VALUES
                (3, \(now.timeIntervalSince1970), 'R', 1000, 'alpha', 101),
                (3, \(now.timeIntervalSince1970), 'W', 500, 'alpha', 101),
                (3, \(now.timeIntervalSince1970), 'R', 2000, 'beta', 102),
                (3, \(now.timeIntervalSince1970), 'W', 100, 'beta', 102);
            """,
            on: connection
        )
        try execute(
            """
            INSERT INTO events
                (id, snapshot_id, timestamp, type, severity, value, message)
            VALUES
                (1, 3, \(now.addingTimeInterval(-30).timeIntervalSince1970),
                 'CPU_SPIKE', 'warning', 85.0, 'CPU threshold'),
                (2, 3, \(now.timeIntervalSince1970),
                 'MEMORY_SPIKE', 'critical', 92.0, 'RAM threshold'),
                (3, 3, \(now.addingTimeInterval(-60).timeIntervalSince1970),
                 'DISK_SPIKE', 'info', 12.0, 'Disk threshold');
            """,
            on: connection
        )
        try execute(
            """
            INSERT INTO hourly_system_stats
                (bucket_start, sample_count, cpu_avg, cpu_max, memory_avg, memory_max,
                 disk_read_avg, disk_read_max, disk_write_avg, disk_write_max,
                 network_in_avg, network_in_max, network_out_avg, network_out_max,
                 disk_event_count, disk_event_bytes, anomaly_count, dropped_events_sum)
            VALUES (\(now.addingTimeInterval(-3600).timeIntervalSince1970), 1,
                    20.0, 40.0, 30.0, 50.0, 2.0, 4.0, 3.0, 5.0,
                    4.0, 6.0, 5.0, 7.0, 4, 3600, 3, 2);
            """,
            on: connection
        )
    }

    private func execute(_ sql: String, on connection: OpaquePointer?) throws {
        guard let connection else {
            throw FixtureError.couldNotOpen
        }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMessage)
            throw FixtureError.sqlite(message)
        }
    }

    private var schema: String {
        """
        CREATE TABLE system_samples (
            id INTEGER PRIMARY KEY,
            timestamp REAL NOT NULL,
            cpu REAL NOT NULL,
            memory REAL NOT NULL,
            disk_read REAL NOT NULL,
            disk_write REAL NOT NULL,
            network_in REAL NOT NULL,
            network_out REAL NOT NULL,
            dropped_events INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE process_samples (
            id INTEGER PRIMARY KEY,
            snapshot_id INTEGER NOT NULL,
            timestamp REAL NOT NULL,
            pid INTEGER NOT NULL,
            name TEXT NOT NULL,
            cpu REAL NOT NULL,
            memory INTEGER NOT NULL,
            disk_read_bytes INTEGER NOT NULL DEFAULT 0,
            disk_write_bytes INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE disk_process_events (
            id INTEGER PRIMARY KEY,
            snapshot_id INTEGER,
            timestamp REAL NOT NULL,
            operation TEXT NOT NULL,
            bytes INTEGER NOT NULL,
            process_name TEXT NOT NULL,
            pid INTEGER NOT NULL
        );
        CREATE TABLE events (
            id INTEGER PRIMARY KEY,
            snapshot_id INTEGER NOT NULL,
            timestamp REAL NOT NULL,
            type TEXT NOT NULL,
            severity TEXT NOT NULL,
            value REAL NOT NULL,
            message TEXT NOT NULL
        );
        CREATE TABLE hourly_system_stats (
            bucket_start REAL PRIMARY KEY,
            sample_count INTEGER NOT NULL,
            cpu_avg REAL NOT NULL,
            cpu_max REAL NOT NULL,
            memory_avg REAL NOT NULL,
            memory_max REAL NOT NULL,
            disk_read_avg REAL NOT NULL,
            disk_read_max REAL NOT NULL,
            disk_write_avg REAL NOT NULL,
            disk_write_max REAL NOT NULL,
            network_in_avg REAL NOT NULL,
            network_in_max REAL NOT NULL,
            network_out_avg REAL NOT NULL,
            network_out_max REAL NOT NULL,
            disk_event_count INTEGER NOT NULL,
            disk_event_bytes INTEGER NOT NULL,
            anomaly_count INTEGER NOT NULL,
            dropped_events_sum INTEGER NOT NULL
        );
        CREATE TABLE daily_system_stats (bucket_start REAL PRIMARY KEY);
        CREATE TABLE hourly_process_stats (bucket_start REAL, pid INTEGER);
        CREATE TABLE daily_process_stats (bucket_start REAL, pid INTEGER);
        CREATE INDEX idx_system_samples_timestamp ON system_samples(timestamp);
        CREATE INDEX idx_process_samples_snapshot_cpu ON process_samples(snapshot_id, cpu DESC);
        CREATE INDEX idx_disk_process_events_snapshot_id ON disk_process_events(snapshot_id);
        """
    }
}

enum FixtureError: Error {
    case couldNotOpen
    case sqlite(String)
}

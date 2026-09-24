import Foundation
import SQLite3

// SQLITE_TRANSIENT tells SQLite to copy the bound bytes before
// sqlite3_bind_text returns. The temporary pointer provided by
// String.withCString therefore never needs to outlive its closure.
private let sqliteTransient = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)

private struct DatabaseOperationError: Error, CustomStringConvertible {
    let operation: String
    let message: String

    var description: String {
        "\(operation): \(message)"
    }
}

private enum SQLiteBinding {
    case integer(Int64)
    case double(Double)
    case null
}

final class Database {

    private static let currentSchemaVersion: Int32 = 2

    private var database: OpaquePointer?
    private let retentionPolicy: DatabaseRetentionPolicy
    private let logWrites: Bool
    private let inMemoryDatabase: Bool

    private var systemSampleInsertStatement: OpaquePointer?
    private var processSampleInsertStatement: OpaquePointer?
    private var diskProcessEventInsertStatement: OpaquePointer?
    private var eventInsertStatement: OpaquePointer?

    init(
        databasePath: String? = nil,
        retentionPolicy: DatabaseRetentionPolicy = .standard,
        logWrites: Bool = true
    ) {
        self.retentionPolicy = retentionPolicy
        self.logWrites = logWrites

        let fileManager = FileManager.default
        let path: String

        if let databasePath {
            path = databasePath
        } else {
            let projectRoot = URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()

            let databaseDirectory = projectRoot
                .appendingPathComponent("data/database", isDirectory: true)

            try? fileManager.createDirectory(
                at: databaseDirectory,
                withIntermediateDirectories: true
            )

            path = databaseDirectory
                .appendingPathComponent("mac_detective.sqlite")
                .path
        }

        self.inMemoryDatabase = path == ":memory:" ||
            path.contains("mode=memory")

        let openResult = sqlite3_open(path, &database)

        guard openResult == SQLITE_OK else {
            let message = database.map {
                String(cString: sqlite3_errmsg($0))
            } ?? "unknown SQLite error"

            print("❌ Impossible d'ouvrir SQLite: \(message)")
            sqlite3_close(database)
            database = nil
            return
        }

        print("SQLite database:")
        print(path)
        createTables()
    }

    deinit {
        finalizeCachedStatements()
        sqlite3_close(database)
    }

    // MARK: - Schema and migrations

    private func createTables() {

        do {
            try configureConnection()
            try migrateSchema()
            print("Database schema ready (version \(Self.currentSchemaVersion))")
        } catch {
            print("❌ SQLite schema error: \(error)")
        }
    }

    private func configureConnection() throws {
        try execute(query: "PRAGMA busy_timeout = 5000;")
        // The application has one writer and occasional readers. WAL avoids
        // reader/writer blocking while preserving SQLite transactions.
        try execute(query: "PRAGMA journal_mode = WAL;")
        let actualJournalMode = try scalarText("PRAGMA journal_mode;")
        if !inMemoryDatabase, actualJournalMode.lowercased() != "wal" {
            throw DatabaseOperationError(
                operation: "Enable WAL",
                message: "SQLite reported journal mode \(actualJournalMode)"
            )
        }
        try execute(query: "PRAGMA foreign_keys = ON;")
    }

    private func migrateSchema() throws {

        let version = try schemaVersion()

        guard version <= Self.currentSchemaVersion else {
            throw DatabaseOperationError(
                operation: "Unsupported database schema",
                message: "version \(version) is newer than supported version \(Self.currentSchemaVersion)"
            )
        }

        guard version < Self.currentSchemaVersion else {
            return
        }

        try execute(query: "BEGIN IMMEDIATE TRANSACTION;")

        do {
            try createBaseTables()

            if try !tableHasColumn("system_samples", "dropped_events") {
                try execute(query: """
                    ALTER TABLE system_samples
                    ADD COLUMN dropped_events INTEGER NOT NULL DEFAULT 0;
                """)
            }

            if try !tableHasColumn("process_samples", "disk_read_bytes") {
                try execute(query: """
                    ALTER TABLE process_samples
                    ADD COLUMN disk_read_bytes INTEGER NOT NULL DEFAULT 0;
                """)
            }

            if try !tableHasColumn("process_samples", "disk_write_bytes") {
                try execute(query: """
                    ALTER TABLE process_samples
                    ADD COLUMN disk_write_bytes INTEGER NOT NULL DEFAULT 0;
                """)
            }

            try execute(query: """
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
            """)

            try execute(query: """
                CREATE INDEX IF NOT EXISTS idx_disk_process_events_snapshot_id
                ON disk_process_events(snapshot_id);
            """)

            try execute(query: """
                CREATE INDEX IF NOT EXISTS idx_process_samples_snapshot_cpu
                ON process_samples(snapshot_id, cpu DESC);
            """)

            try createAggregateTables()

            try execute(query: """
                CREATE INDEX IF NOT EXISTS idx_system_samples_timestamp
                ON system_samples(timestamp);
            """)

            try execute(query: """
                CREATE INDEX IF NOT EXISTS idx_events_snapshot_id
                ON events(snapshot_id);
            """)

            try execute(
                query: "PRAGMA user_version = \(Self.currentSchemaVersion);"
            )
            try execute(query: "COMMIT;")
        } catch {
            _ = try? execute(query: "ROLLBACK;")
            throw error
        }
    }

    private func createBaseTables() throws {

        try execute(query: """
            CREATE TABLE IF NOT EXISTS system_samples (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp REAL NOT NULL,
                cpu REAL NOT NULL,
                memory REAL NOT NULL,
                disk_read REAL NOT NULL,
                disk_write REAL NOT NULL,
                network_in REAL NOT NULL,
                network_out REAL NOT NULL,
                dropped_events INTEGER NOT NULL DEFAULT 0
            );
        """)

        try execute(query: """
            CREATE TABLE IF NOT EXISTS process_samples (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                snapshot_id INTEGER NOT NULL,
                timestamp REAL NOT NULL,
                pid INTEGER NOT NULL,
                name TEXT NOT NULL,
                cpu REAL NOT NULL,
                memory INTEGER NOT NULL,
                disk_read_bytes INTEGER NOT NULL DEFAULT 0,
                disk_write_bytes INTEGER NOT NULL DEFAULT 0,
                FOREIGN KEY(snapshot_id) REFERENCES system_samples(id)
            );
        """)

        try execute(query: """
            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                snapshot_id INTEGER NOT NULL,
                timestamp REAL NOT NULL,
                type TEXT NOT NULL,
                severity TEXT NOT NULL,
                value REAL NOT NULL,
                message TEXT NOT NULL,
                FOREIGN KEY(snapshot_id) REFERENCES system_samples(id)
            );
        """)
    }

    private func createAggregateTables() throws {
        try execute(query: """
            CREATE TABLE IF NOT EXISTS hourly_system_stats (
                bucket_start REAL NOT NULL PRIMARY KEY,
                sample_count INTEGER NOT NULL,
                cpu_avg REAL NOT NULL,
                cpu_max REAL NOT NULL,
                memory_avg REAL NOT NULL,
                memory_max REAL NOT NULL,
                disk_read_sum REAL NOT NULL,
                disk_read_avg REAL NOT NULL,
                disk_read_max REAL NOT NULL,
                disk_write_sum REAL NOT NULL,
                disk_write_avg REAL NOT NULL,
                disk_write_max REAL NOT NULL,
                network_in_sum REAL NOT NULL,
                network_in_avg REAL NOT NULL,
                network_in_max REAL NOT NULL,
                network_out_sum REAL NOT NULL,
                network_out_avg REAL NOT NULL,
                network_out_max REAL NOT NULL,
                disk_event_count INTEGER NOT NULL,
                disk_event_bytes INTEGER NOT NULL,
                anomaly_count INTEGER NOT NULL,
                dropped_events_sum INTEGER NOT NULL
            );
        """)

        try execute(query: """
            CREATE TABLE IF NOT EXISTS daily_system_stats (
                bucket_start REAL NOT NULL PRIMARY KEY,
                sample_count INTEGER NOT NULL,
                cpu_avg REAL NOT NULL,
                cpu_max REAL NOT NULL,
                memory_avg REAL NOT NULL,
                memory_max REAL NOT NULL,
                disk_read_sum REAL NOT NULL,
                disk_read_avg REAL NOT NULL,
                disk_read_max REAL NOT NULL,
                disk_write_sum REAL NOT NULL,
                disk_write_avg REAL NOT NULL,
                disk_write_max REAL NOT NULL,
                network_in_sum REAL NOT NULL,
                network_in_avg REAL NOT NULL,
                network_in_max REAL NOT NULL,
                network_out_sum REAL NOT NULL,
                network_out_avg REAL NOT NULL,
                network_out_max REAL NOT NULL,
                disk_event_count INTEGER NOT NULL,
                disk_event_bytes INTEGER NOT NULL,
                anomaly_count INTEGER NOT NULL,
                dropped_events_sum INTEGER NOT NULL
            );
        """)

        try execute(query: """
            CREATE TABLE IF NOT EXISTS hourly_process_stats (
                bucket_start REAL NOT NULL,
                pid INTEGER NOT NULL,
                process_name TEXT NOT NULL,
                sample_count INTEGER NOT NULL,
                cpu_avg REAL NOT NULL,
                cpu_max REAL NOT NULL,
                memory_avg REAL NOT NULL,
                memory_max REAL NOT NULL,
                disk_read_sum INTEGER NOT NULL,
                disk_read_avg REAL NOT NULL,
                disk_read_max INTEGER NOT NULL,
                disk_write_sum INTEGER NOT NULL,
                disk_write_avg REAL NOT NULL,
                disk_write_max INTEGER NOT NULL,
                PRIMARY KEY (bucket_start, pid, process_name)
            );
        """)

        try execute(query: """
            CREATE TABLE IF NOT EXISTS daily_process_stats (
                bucket_start REAL NOT NULL,
                pid INTEGER NOT NULL,
                process_name TEXT NOT NULL,
                sample_count INTEGER NOT NULL,
                cpu_avg REAL NOT NULL,
                cpu_max REAL NOT NULL,
                memory_avg REAL NOT NULL,
                memory_max REAL NOT NULL,
                disk_read_sum INTEGER NOT NULL,
                disk_read_avg REAL NOT NULL,
                disk_read_max INTEGER NOT NULL,
                disk_write_sum INTEGER NOT NULL,
                disk_write_avg REAL NOT NULL,
                disk_write_max INTEGER NOT NULL,
                PRIMARY KEY (bucket_start, pid, process_name)
            );
        """)
    }

    private func schemaVersion() throws -> Int32 {
        var statement: OpaquePointer?

        try prepare(
            query: "PRAGMA user_version;",
            statement: &statement,
            operation: "Read database schema version"
        )
        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw operationError("Read database schema version")
        }

        return sqlite3_column_int(statement, 0)
    }

    private func tableHasColumn(
        _ table: String,
        _ column: String
    ) throws -> Bool {

        var statement: OpaquePointer?

        try prepare(
            query: "PRAGMA table_info(\(table));",
            statement: &statement,
            operation: "Inspect table \(table)"
        )
        defer {
            sqlite3_finalize(statement)
        }

        while true {
            let result = sqlite3_step(statement)

            if result == SQLITE_DONE {
                return false
            }

            guard result == SQLITE_ROW else {
                throw operationError("Inspect table \(table)")
            }

            guard let namePointer = sqlite3_column_text(statement, 1) else {
                continue
            }

            if String(cString: namePointer) == column {
                return true
            }
        }
    }

    @discardableResult
    private func execute(query: String) throws -> Int32 {

        guard let database else {
            throw DatabaseOperationError(
                operation: "SQLite statement",
                message: "database is not open"
            )
        }

        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(
            database,
            query,
            nil,
            nil,
            &errorMessage
        )

        guard result == SQLITE_OK else {
            let message = errorMessage.map {
                String(cString: $0)
            } ?? String(cString: sqlite3_errmsg(database))

            sqlite3_free(errorMessage)
            throw DatabaseOperationError(
                operation: "SQLite statement",
                message: message
            )
        }

        return result
    }

    @discardableResult
    private func executeCount(
        query: String,
        bindings: [SQLiteBinding]
    ) throws -> Int {
        var statement: OpaquePointer?
        try prepare(
            query: query,
            statement: &statement,
            operation: "Prepare counted statement"
        )
        defer {
            sqlite3_finalize(statement)
        }

        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32

            switch binding {
            case .integer(let value):
                result = sqlite3_bind_int64(statement, index, value)
            case .double(let value):
                result = sqlite3_bind_double(statement, index, value)
            case .null:
                result = sqlite3_bind_null(statement, index)
            }

            try checkBind(result, operation: "Bind counted statement")
        }

        try step(statement, operation: "Execute counted statement")

        guard let database else {
            throw DatabaseOperationError(
                operation: "Read changed row count",
                message: "database is not open"
            )
        }

        return Int(sqlite3_changes(database))
    }

    private func scalarText(_ query: String) throws -> String {
        var statement: OpaquePointer?
        try prepare(
            query: query,
            statement: &statement,
            operation: "Read scalar value"
        )
        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let pointer = sqlite3_column_text(statement, 0) else {
            throw operationError("Read scalar value")
        }

        return String(cString: pointer)
    }

    private func cachedStatement(
        query: String,
        current: inout OpaquePointer?,
        operation: String
    ) throws -> OpaquePointer {
        if let current {
            return current
        }

        var statement: OpaquePointer?
        try prepare(
            query: query,
            statement: &statement,
            operation: operation
        )

        guard let statement else {
            throw DatabaseOperationError(
                operation: operation,
                message: "SQLite returned a null statement"
            )
        }

        current = statement
        return statement
    }

    private func resetStatement(_ statement: OpaquePointer?) {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    private func finalizeCachedStatements() {
        sqlite3_finalize(systemSampleInsertStatement)
        sqlite3_finalize(processSampleInsertStatement)
        sqlite3_finalize(diskProcessEventInsertStatement)
        sqlite3_finalize(eventInsertStatement)
    }

    var journalMode: String {
        (try? scalarText("PRAGMA journal_mode;")) ?? ""
    }

    private func prepare(
        query: String,
        statement: inout OpaquePointer?,
        operation: String
    ) throws {

        guard database != nil else {
            throw DatabaseOperationError(
                operation: operation,
                message: "database is not open"
            )
        }

        let result = sqlite3_prepare_v2(
            database,
            query,
            -1,
            &statement,
            nil
        )

        guard result == SQLITE_OK else {
            throw DatabaseOperationError(
                operation: operation,
                message: operationError(operation).message
            )
        }
    }

    private func operationError(
        _ operation: String
    ) -> DatabaseOperationError {

        let message = database.map {
            String(cString: sqlite3_errmsg($0))
        } ?? "database is not open"

        return DatabaseOperationError(
            operation: operation,
            message: message
        )
    }

    // MARK: - Save snapshot

    @discardableResult
    func save(snapshot: SystemSnapshot) -> Int64? {
        save(snapshot: snapshot, diskProcessEvents: [])
    }

    @discardableResult
    func save(
        snapshot: SystemSnapshot,
        diskProcessEvents: [DiskProcessEvent]
    ) -> Int64? {

        do {
            let snapshotID = try saveSnapshotAtomically(
                snapshot: snapshot,
                diskProcessEvents: diskProcessEvents
            )

            if logWrites {
                print(
                    "Snapshot saved to SQLite (\(snapshot.processes.count) processes, \(diskProcessEvents.count) disk events)"
                )
            }
            return snapshotID
        } catch {
            print("❌ Impossible d'enregistrer le snapshot: \(error)")
            return nil
        }
    }

    private func saveSnapshotAtomically(
        snapshot: SystemSnapshot,
        diskProcessEvents: [DiskProcessEvent]
    ) throws -> Int64 {

        try execute(query: "BEGIN IMMEDIATE TRANSACTION;")

        do {
            let snapshotID = try insertSystemSample(snapshot)
            try insertProcessSamples(
                snapshot.processes,
                snapshotID: snapshotID,
                timestamp: snapshot.timestamp
            )
            try insertDiskProcessEvents(
                diskProcessEvents,
                snapshotID: snapshotID
            )
            try execute(query: "COMMIT;")
            return snapshotID
        } catch {
            _ = try? execute(query: "ROLLBACK;")
            throw error
        }
    }

    private func insertSystemSample(
        _ snapshot: SystemSnapshot
    ) throws -> Int64 {

        let statement = try cachedStatement(
            query: """
            INSERT INTO system_samples (
                timestamp,
                cpu,
                memory,
                disk_read,
                disk_write,
                network_in,
                network_out,
                dropped_events
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """,
            current: &systemSampleInsertStatement,
            operation: "Prepare system sample insert"
        )
        resetStatement(statement)

        do {
            try checkBind(
                sqlite3_bind_double(
                    statement,
                    1,
                    snapshot.timestamp.timeIntervalSince1970
                ),
                operation: "Bind system sample timestamp"
            )
            try checkBind(
                sqlite3_bind_double(statement, 2, snapshot.cpu),
                operation: "Bind system sample CPU"
            )
            try checkBind(
                sqlite3_bind_double(statement, 3, snapshot.memory),
                operation: "Bind system sample memory"
            )
            try checkBind(
                sqlite3_bind_double(statement, 4, snapshot.diskRead),
                operation: "Bind system sample disk read"
            )
            try checkBind(
                sqlite3_bind_double(statement, 5, snapshot.diskWrite),
                operation: "Bind system sample disk write"
            )
            try checkBind(
                sqlite3_bind_double(statement, 6, snapshot.networkIn),
                operation: "Bind system sample network in"
            )
            try checkBind(
                sqlite3_bind_double(statement, 7, snapshot.networkOut),
                operation: "Bind system sample network out"
            )
            try checkBind(
                sqlite3_bind_int64(
                    statement,
                    8,
                    Int64(snapshot.droppedEvents)
                ),
                operation: "Bind system sample dropped events"
            )
            try step(statement, operation: "Insert system sample")
        } catch {
            resetStatement(statement)
            throw error
        }

        guard let database else {
            throw DatabaseOperationError(
                operation: "Read inserted snapshot ID",
                message: "database is not open"
            )
        }

        let snapshotID = sqlite3_last_insert_rowid(database)
        resetStatement(statement)
        return snapshotID
    }

    private func insertProcessSamples(
        _ processes: [ProcessSnapshot],
        snapshotID: Int64,
        timestamp: Date
    ) throws {

        guard !processes.isEmpty else {
            return
        }

        let statement = try cachedStatement(
            query: """
            INSERT INTO process_samples (
                snapshot_id,
                timestamp,
                pid,
                name,
                cpu,
                memory,
                disk_read_bytes,
                disk_write_bytes
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """,
            current: &processSampleInsertStatement,
            operation: "Prepare process sample insert"
        )

        do {
            for process in processes {
                resetStatement(statement)

                try checkBind(
                    sqlite3_bind_int64(statement, 1, snapshotID),
                    operation: "Bind process snapshot ID"
                )
                try checkBind(
                    sqlite3_bind_double(
                        statement,
                        2,
                        timestamp.timeIntervalSince1970
                    ),
                    operation: "Bind process timestamp"
                )
                try checkBind(
                    sqlite3_bind_int(statement, 3, process.pid),
                    operation: "Bind process PID"
                )
                try bindText(
                    process.name,
                    to: statement,
                    at: 4,
                    operation: "Bind process name"
                )
                try checkBind(
                    sqlite3_bind_double(statement, 5, process.cpuUsage),
                    operation: "Bind process CPU"
                )
                try checkBind(
                    sqlite3_bind_int64(
                        statement,
                        6,
                        try int64Value(
                            process.memoryBytes,
                            operation: "Encode process memory"
                        )
                    ),
                    operation: "Bind process memory"
                )
                try checkBind(
                    sqlite3_bind_int64(
                        statement,
                        7,
                        try int64Value(
                            process.diskReadBytes,
                            operation: "Encode process disk read"
                        )
                    ),
                    operation: "Bind process disk read"
                )
                try checkBind(
                    sqlite3_bind_int64(
                        statement,
                        8,
                        try int64Value(
                            process.diskWriteBytes,
                            operation: "Encode process disk write"
                        )
                    ),
                    operation: "Bind process disk write"
                )
                try step(statement, operation: "Insert process sample")
            }
        } catch {
            resetStatement(statement)
            throw error
        }

        resetStatement(statement)
    }

    private func insertDiskProcessEvents(
        _ events: [DiskProcessEvent],
        snapshotID: Int64?
    ) throws {

        guard !events.isEmpty else {
            return
        }

        let statement = try cachedStatement(
            query: """
            INSERT INTO disk_process_events (
                snapshot_id,
                timestamp,
                operation,
                bytes,
                process_name,
                pid
            )
            VALUES (?, ?, ?, ?, ?, ?);
            """,
            current: &diskProcessEventInsertStatement,
            operation: "Prepare disk process event insert"
        )

        do {
            for event in events {
                resetStatement(statement)

                if let snapshotID {
                    try checkBind(
                        sqlite3_bind_int64(statement, 1, snapshotID),
                        operation: "Bind disk event snapshot ID"
                    )
                } else {
                    try checkBind(
                        sqlite3_bind_null(statement, 1),
                        operation: "Bind null disk event snapshot ID"
                    )
                }

                try checkBind(
                    sqlite3_bind_double(
                        statement,
                        2,
                        event.timestamp.timeIntervalSince1970
                    ),
                    operation: "Bind disk event timestamp"
                )
                try bindText(
                    event.operation,
                    to: statement,
                    at: 3,
                    operation: "Bind disk event operation"
                )
                try checkBind(
                    sqlite3_bind_int64(
                        statement,
                        4,
                        try int64Value(
                            event.bytes,
                            operation: "Encode disk event bytes"
                        )
                    ),
                    operation: "Bind disk event bytes"
                )
                try bindText(
                    event.processName,
                    to: statement,
                    at: 5,
                    operation: "Bind disk event process name"
                )
                try checkBind(
                    sqlite3_bind_int(statement, 6, event.pid),
                    operation: "Bind disk event PID"
                )
                try step(statement, operation: "Insert disk process event")
            }
        } catch {
            resetStatement(statement)
            throw error
        }

        resetStatement(statement)
    }

    // MARK: - Aggregation and retention

    private func refreshSystemStats(
        table: String,
        bucketModifier: String
    ) throws -> Int {
        let bucketExpression: String
        switch bucketModifier {
        case "hour":
            bucketExpression = """
                CAST(strftime('%s', strftime('%Y-%m-%d %H:00:00', s.timestamp, 'unixepoch')) AS REAL)
            """
        case "day":
            bucketExpression = """
                CAST(strftime('%s', strftime('%Y-%m-%d 00:00:00', s.timestamp, 'unixepoch')) AS REAL)
            """
        default:
            throw DatabaseOperationError(
                operation: "Build aggregate bucket",
                message: "Unsupported bucket modifier \(bucketModifier)"
            )
        }

        let query = """
        INSERT OR REPLACE INTO \(table) (
            bucket_start,
            sample_count,
            cpu_avg,
            cpu_max,
            memory_avg,
            memory_max,
            disk_read_sum,
            disk_read_avg,
            disk_read_max,
            disk_write_sum,
            disk_write_avg,
            disk_write_max,
            network_in_sum,
            network_in_avg,
            network_in_max,
            network_out_sum,
            network_out_avg,
            network_out_max,
            disk_event_count,
            disk_event_bytes,
            anomaly_count,
            dropped_events_sum
        )
        SELECT
            \(bucketExpression) AS bucket_start,
            COUNT(*) AS sample_count,
            AVG(s.cpu) AS cpu_avg,
            MAX(s.cpu) AS cpu_max,
            AVG(s.memory) AS memory_avg,
            MAX(s.memory) AS memory_max,
            SUM(s.disk_read) AS disk_read_sum,
            AVG(s.disk_read) AS disk_read_avg,
            MAX(s.disk_read) AS disk_read_max,
            SUM(s.disk_write) AS disk_write_sum,
            AVG(s.disk_write) AS disk_write_avg,
            MAX(s.disk_write) AS disk_write_max,
            SUM(s.network_in) AS network_in_sum,
            AVG(s.network_in) AS network_in_avg,
            MAX(s.network_in) AS network_in_max,
            SUM(s.network_out) AS network_out_sum,
            AVG(s.network_out) AS network_out_avg,
            MAX(s.network_out) AS network_out_max,
            COALESCE(SUM(d.event_count), 0) AS disk_event_count,
            COALESCE(SUM(d.event_bytes), 0) AS disk_event_bytes,
            COALESCE(SUM(e.anomaly_count), 0) AS anomaly_count,
            COALESCE(SUM(s.dropped_events), 0) AS dropped_events_sum
        FROM system_samples s
        LEFT JOIN (
            SELECT
                snapshot_id,
                COUNT(*) AS event_count,
                COALESCE(SUM(bytes), 0) AS event_bytes
            FROM disk_process_events
            WHERE snapshot_id IS NOT NULL
            GROUP BY snapshot_id
        ) d ON d.snapshot_id = s.id
        LEFT JOIN (
            SELECT
                snapshot_id,
                COUNT(*) AS anomaly_count
            FROM events
            GROUP BY snapshot_id
        ) e ON e.snapshot_id = s.id
        GROUP BY bucket_start;
        """

        return try executeCount(query: query, bindings: [])
    }

    private func refreshProcessStats(
        table: String,
        bucketModifier: String
    ) throws -> Int {
        let bucketExpression: String
        switch bucketModifier {
        case "hour":
            bucketExpression = """
                CAST(strftime('%s', strftime('%Y-%m-%d %H:00:00', timestamp, 'unixepoch')) AS REAL)
            """
        case "day":
            bucketExpression = """
                CAST(strftime('%s', strftime('%Y-%m-%d 00:00:00', timestamp, 'unixepoch')) AS REAL)
            """
        default:
            throw DatabaseOperationError(
                operation: "Build process aggregate bucket",
                message: "Unsupported bucket modifier \(bucketModifier)"
            )
        }

        let query = """
        INSERT OR REPLACE INTO \(table) (
            bucket_start,
            pid,
            process_name,
            sample_count,
            cpu_avg,
            cpu_max,
            memory_avg,
            memory_max,
            disk_read_sum,
            disk_read_avg,
            disk_read_max,
            disk_write_sum,
            disk_write_avg,
            disk_write_max
        )
        SELECT
            \(bucketExpression) AS bucket_start,
            pid,
            name AS process_name,
            COUNT(*) AS sample_count,
            AVG(cpu) AS cpu_avg,
            MAX(cpu) AS cpu_max,
            AVG(memory) AS memory_avg,
            MAX(memory) AS memory_max,
            SUM(disk_read_bytes) AS disk_read_sum,
            AVG(disk_read_bytes) AS disk_read_avg,
            MAX(disk_read_bytes) AS disk_read_max,
            SUM(disk_write_bytes) AS disk_write_sum,
            AVG(disk_write_bytes) AS disk_write_avg,
            MAX(disk_write_bytes) AS disk_write_max
        FROM process_samples
        GROUP BY bucket_start, pid, name;
        """

        return try executeCount(query: query, bindings: [])
    }

    private func refreshAggregates() throws -> (
        hourlySystem: Int,
        hourlyProcess: Int,
        dailySystem: Int,
        dailyProcess: Int
    ) {
        (
            try refreshSystemStats(
                table: "hourly_system_stats",
                bucketModifier: "hour"
            ),
            try refreshProcessStats(
                table: "hourly_process_stats",
                bucketModifier: "hour"
            ),
            try refreshSystemStats(
                table: "daily_system_stats",
                bucketModifier: "day"
            ),
            try refreshProcessStats(
                table: "daily_process_stats",
                bucketModifier: "day"
            )
        )
    }

    func performMaintenance(now: Date = Date()) throws -> DatabaseMaintenanceReport {
        let detailedCutoff = retentionPolicy.cutoff(
            afterDays: retentionPolicy.detailedRetentionDays,
            now: now
        )
        let hourlyCutoff = retentionPolicy.cutoff(
            afterDays: retentionPolicy.hourlyRetentionDays,
            now: now
        )
        let dailyCutoff = retentionPolicy.cutoff(
            afterDays: retentionPolicy.dailyRetentionDays,
            now: now
        )

        try execute(query: "BEGIN IMMEDIATE TRANSACTION;")

        do {
            // Aggregate before deleting detailed rows. Re-running maintenance
            // is safe because INSERT OR REPLACE refreshes existing buckets.
            let refreshed = try refreshAggregates()

            let deletedProcessSamples = try executeCount(
                query: """
                DELETE FROM process_samples
                WHERE snapshot_id IN (
                    SELECT id FROM system_samples WHERE timestamp < ?
                );
                """,
                bindings: [.double(detailedCutoff.timeIntervalSince1970)]
            )
            let deletedDiskProcessEvents = try executeCount(
                query: """
                DELETE FROM disk_process_events
                WHERE (
                    snapshot_id IS NULL AND timestamp < ?
                ) OR snapshot_id IN (
                    SELECT id FROM system_samples WHERE timestamp < ?
                );
                """,
                bindings: [
                    .double(detailedCutoff.timeIntervalSince1970),
                    .double(detailedCutoff.timeIntervalSince1970)
                ]
            )
            let deletedEvents = try executeCount(
                query: """
                DELETE FROM events
                WHERE snapshot_id IN (
                    SELECT id FROM system_samples WHERE timestamp < ?
                );
                """,
                bindings: [.double(detailedCutoff.timeIntervalSince1970)]
            )
            let deletedSystemSamples = try executeCount(
                query: "DELETE FROM system_samples WHERE timestamp < ?;",
                bindings: [.double(detailedCutoff.timeIntervalSince1970)]
            )

            let deletedHourlySystemStats = try executeCount(
                query: "DELETE FROM hourly_system_stats WHERE bucket_start < ?;",
                bindings: [.double(hourlyCutoff.timeIntervalSince1970)]
            )
            let deletedHourlyProcessStats = try executeCount(
                query: "DELETE FROM hourly_process_stats WHERE bucket_start < ?;",
                bindings: [.double(hourlyCutoff.timeIntervalSince1970)]
            )
            let deletedDailySystemStats = try executeCount(
                query: "DELETE FROM daily_system_stats WHERE bucket_start < ?;",
                bindings: [.double(dailyCutoff.timeIntervalSince1970)]
            )
            let deletedDailyProcessStats = try executeCount(
                query: "DELETE FROM daily_process_stats WHERE bucket_start < ?;",
                bindings: [.double(dailyCutoff.timeIntervalSince1970)]
            )

            try execute(query: "COMMIT;")

            let report = DatabaseMaintenanceReport(
                deletedSystemSamples: deletedSystemSamples,
                deletedProcessSamples: deletedProcessSamples,
                deletedDiskProcessEvents: deletedDiskProcessEvents,
                deletedEvents: deletedEvents,
                deletedHourlySystemStats: deletedHourlySystemStats,
                deletedHourlyProcessStats: deletedHourlyProcessStats,
                deletedDailySystemStats: deletedDailySystemStats,
                deletedDailyProcessStats: deletedDailyProcessStats,
                refreshedHourlySystemStats: refreshed.hourlySystem,
                refreshedHourlyProcessStats: refreshed.hourlyProcess,
                refreshedDailySystemStats: refreshed.dailySystem,
                refreshedDailyProcessStats: refreshed.dailyProcess
            )

            if logWrites {
                print(
                    "Database maintenance: \(report.totalDeleted) rows deleted"
                )
            }

            return report
        } catch {
            _ = try? execute(query: "ROLLBACK;")
            throw error
        }
    }

    func checkpoint() throws {
        try execute(query: "PRAGMA wal_checkpoint(PASSIVE);")
    }

    private func bindText(
        _ value: String,
        to statement: OpaquePointer?,
        at index: Int32,
        operation: String
    ) throws {

        var bindResult = SQLITE_ERROR
        value.withCString { pointer in
            bindResult = sqlite3_bind_text(
                statement,
                index,
                pointer,
                -1,
                sqliteTransient
            )
        }
        try checkBind(bindResult, operation: operation)
    }

    private func checkBind(
        _ result: Int32,
        operation: String
    ) throws {

        guard result == SQLITE_OK else {
            throw DatabaseOperationError(
                operation: operation,
                message: operationError(operation).message
            )
        }
    }

    private func step(
        _ statement: OpaquePointer?,
        operation: String
    ) throws {

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseOperationError(
                operation: operation,
                message: operationError(operation).message
            )
        }
    }

    private func int64Value(
        _ value: UInt64,
        operation: String
    ) throws -> Int64 {

        guard value <= UInt64(Int64.max) else {
            throw DatabaseOperationError(
                operation: operation,
                message: "value exceeds SQLite INTEGER capacity"
            )
        }

        return Int64(value)
    }

    func saveEvent(
        _ event: DetectedEvent,
        snapshotID: Int64,
        timestamp: Date
    ) {
        do {
            let statement = try cachedStatement(
                query: """
                INSERT INTO events (
                    snapshot_id,
                    timestamp,
                    type,
                    severity,
                    value,
                    message
                )
                VALUES (?, ?, ?, ?, ?, ?);
                """,
                current: &eventInsertStatement,
                operation: "Prepare event insert"
            )
            resetStatement(statement)

            try checkBind(
                sqlite3_bind_int64(statement, 1, snapshotID),
                operation: "Bind event snapshot ID"
            )
            try checkBind(
                sqlite3_bind_double(
                    statement,
                    2,
                    timestamp.timeIntervalSince1970
                ),
                operation: "Bind event timestamp"
            )
            try bindText(
                event.type,
                to: statement,
                at: 3,
                operation: "Bind event type"
            )
            try bindText(
                event.severity,
                to: statement,
                at: 4,
                operation: "Bind event severity"
            )
            try checkBind(
                sqlite3_bind_double(statement, 5, event.value),
                operation: "Bind event value"
            )
            try bindText(
                event.message,
                to: statement,
                at: 6,
                operation: "Bind event message"
            )
            try step(statement, operation: "Insert event")
            resetStatement(statement)

            if logWrites {
                print("⚠️ Event saved to SQLite: \(event.type)")
            }
        } catch {
            resetStatement(eventInsertStatement)
            if logWrites {
                print("❌ Impossible d'enregistrer l'événement: \(error)")
            }
        }
    }


    func getTopProcesses(
        snapshotID: Int64,
        limit: Int = 5
    ) -> [ProcessSnapshot] {

        let query = """
        SELECT pid, name, cpu, memory, disk_read_bytes, disk_write_bytes
        FROM process_samples
        WHERE snapshot_id = ?
        ORDER BY cpu DESC
        LIMIT ?;
        """

        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(
            database,
            query,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            print("❌ Impossible de lire les processus")
            return []
        }

        defer {
            sqlite3_finalize(statement)
        }

        sqlite3_bind_int64(statement, 1, snapshotID)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var processes: [ProcessSnapshot] = []

        while sqlite3_step(statement) == SQLITE_ROW {

            let pid = sqlite3_column_int(statement, 0)

            let namePointer = sqlite3_column_text(statement, 1)

            let name = namePointer != nil
                ? String(cString: namePointer!)
                : "Unknown"

            let cpu = sqlite3_column_double(statement, 2)

            let memory = UInt64(
                sqlite3_column_int64(statement, 3)
            )

            let diskRead  = UInt64(sqlite3_column_int64(statement, 4))
            let diskWrite = UInt64(sqlite3_column_int64(statement, 5))

            processes.append(
                ProcessSnapshot(
                    pid: pid,
                    name: name,
                    cpuUsage: cpu,
                    memoryBytes: memory,
                    diskReadBytes: diskRead,
                    diskWriteBytes: diskWrite
                )
            )
        }

        return processes
    }

    // MARK: - Disk Process Events

    @discardableResult
    func saveDiskProcessEvent(
        _ event: DiskProcessEvent,
        snapshotID: Int64? = nil
    ) -> Bool {
        return saveDiskProcessEvents([event], snapshotID: snapshotID) == 1
    }

    @discardableResult
    func saveDiskProcessEvents(
        _ events: [DiskProcessEvent],
        snapshotID: Int64? = nil
    ) -> Int {

        guard !events.isEmpty else {
            return 0
        }

        do {
            try execute(query: "BEGIN IMMEDIATE TRANSACTION;")
            try insertDiskProcessEvents(events, snapshotID: snapshotID)
            try execute(query: "COMMIT;")
            return events.count
        } catch {
            _ = try? execute(query: "ROLLBACK;")
            print("❌ Impossible d'enregistrer les disk_process_events: \(error)")
            return 0
        }
    }

    func getDiskProcessEvents(
        snapshotID: Int64? = nil,
        limit: Int = 100
    ) -> [DiskProcessEvent] {

        var query = """
        SELECT timestamp, operation, bytes, process_name, pid
        FROM disk_process_events
        """

        if snapshotID != nil {
            query += " WHERE snapshot_id = ?"
        }

        query += " ORDER BY id ASC LIMIT ?;"

        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(
            database,
            query,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            print("❌ Impossible de lire les disk_process_events")
            return []
        }

        defer {
            sqlite3_finalize(statement)
        }

        var bindIndex: Int32 = 1
        if let snapshotID {
            sqlite3_bind_int64(statement, bindIndex, snapshotID)
            bindIndex += 1
        }
        sqlite3_bind_int(statement, bindIndex, Int32(limit))

        var events: [DiskProcessEvent] = []

        while sqlite3_step(statement) == SQLITE_ROW {

            let timestamp = Date(
                timeIntervalSince1970: sqlite3_column_double(statement, 0)
            )

            let opPointer = sqlite3_column_text(statement, 1)
            let operation = opPointer != nil ? String(cString: opPointer!) : ""

            let bytes = UInt64(sqlite3_column_int64(statement, 2))

            let namePointer = sqlite3_column_text(statement, 3)
            let processName = namePointer != nil ? String(cString: namePointer!) : "Unknown"

            let pid = sqlite3_column_int(statement, 4)

            events.append(
                DiskProcessEvent(
                    timestamp: timestamp,
                    operation: operation,
                    bytes: bytes,
                    processName: processName,
                    pid: pid
                )
            )
        }

        return events
    }

    // MARK: - Disk Activity Ranking

    func getTopDiskProcesses(
        snapshotID: Int64? = nil,
        limit: Int = 5
    ) -> [DiskProcessSummary] {

        var query = """
        SELECT
            process_name,
            pid,
            COALESCE(SUM(CASE WHEN UPPER(operation) LIKE 'R%' THEN bytes ELSE 0 END), 0) AS read_bytes,
            COALESCE(SUM(CASE WHEN UPPER(operation) LIKE 'W%' THEN bytes ELSE 0 END), 0) AS write_bytes,
            COALESCE(SUM(bytes), 0) AS total_bytes
        FROM disk_process_events
        """

        if snapshotID != nil {
            query += " WHERE snapshot_id = ?"
        }

        query += """
         GROUP BY process_name, pid
        ORDER BY total_bytes DESC, process_name ASC, pid ASC
        LIMIT ?;
        """

        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(
            database,
            query,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            print("❌ Impossible de lire les top disk processes")
            return []
        }

        defer {
            sqlite3_finalize(statement)
        }

        var bindIndex: Int32 = 1
        if let snapshotID {
            sqlite3_bind_int64(statement, bindIndex, snapshotID)
            bindIndex += 1
        }
        sqlite3_bind_int(statement, bindIndex, Int32(limit))

        var summaries: [DiskProcessSummary] = []

        while sqlite3_step(statement) == SQLITE_ROW {

            let namePointer = sqlite3_column_text(statement, 0)
            let processName = namePointer != nil ? String(cString: namePointer!) : "Unknown"

            let pid = sqlite3_column_int(statement, 1)
            let readBytes = UInt64(sqlite3_column_int64(statement, 2))
            let writeBytes = UInt64(sqlite3_column_int64(statement, 3))
            let totalBytes = UInt64(sqlite3_column_int64(statement, 4))

            summaries.append(
                DiskProcessSummary(
                    processName: processName,
                    pid: pid,
                    readBytes: readBytes,
                    writeBytes: writeBytes,
                    totalBytes: totalBytes
                )
            )
        }

        return summaries
    }
}

struct DiskProcessSummary: Sendable, Equatable {
    let processName: String
    let pid: Int32
    let readBytes: UInt64
    let writeBytes: UInt64
    let totalBytes: UInt64
}

typealias DiskProcessProcessSummary = DiskProcessSummary

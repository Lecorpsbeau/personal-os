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

final class Database {

    private static let currentSchemaVersion: Int32 = 1

    private var database: OpaquePointer?

    init(databasePath: String? = nil) {

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
        sqlite3_close(database)
    }

    // MARK: - Schema and migrations

    private func createTables() {

        do {
            try execute(query: "PRAGMA foreign_keys = ON;")
            try migrateSchema()
            print("Database schema ready (version \(Self.currentSchemaVersion))")
        } catch {
            print("❌ SQLite schema error: \(error)")
        }
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
                network_out REAL NOT NULL
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

            print(
                "Snapshot saved to SQLite (\(snapshot.processes.count) processes, \(diskProcessEvents.count) disk events)"
            )
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

        let query = """
        INSERT INTO system_samples (
            timestamp,
            cpu,
            memory,
            disk_read,
            disk_write,
            network_in,
            network_out
        )
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """

        var statement: OpaquePointer?
        try prepare(
            query: query,
            statement: &statement,
            operation: "Prepare system sample insert"
        )
        defer {
            sqlite3_finalize(statement)
        }

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
        try step(statement, operation: "Insert system sample")

        guard let database else {
            throw DatabaseOperationError(
                operation: "Read inserted snapshot ID",
                message: "database is not open"
            )
        }

        return sqlite3_last_insert_rowid(database)
    }

    private func insertProcessSamples(
        _ processes: [ProcessSnapshot],
        snapshotID: Int64,
        timestamp: Date
    ) throws {

        guard !processes.isEmpty else {
            return
        }

        let query = """
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
        """

        var statement: OpaquePointer?
        try prepare(
            query: query,
            statement: &statement,
            operation: "Prepare process sample insert"
        )
        defer {
            sqlite3_finalize(statement)
        }

        for process in processes {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)

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
    }

    private func insertDiskProcessEvents(
        _ events: [DiskProcessEvent],
        snapshotID: Int64?
    ) throws {

        guard !events.isEmpty else {
            return
        }

        let query = """
        INSERT INTO disk_process_events (
            snapshot_id,
            timestamp,
            operation,
            bytes,
            process_name,
            pid
        )
        VALUES (?, ?, ?, ?, ?, ?);
        """

        var statement: OpaquePointer?
        try prepare(
            query: query,
            statement: &statement,
            operation: "Prepare disk process event insert"
        )
        defer {
            sqlite3_finalize(statement)
        }

        for event in events {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)

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

        let query = """
        INSERT INTO events (
            snapshot_id,
            timestamp,
            type,
            severity,
            value,
            message
        )
        VALUES (?, ?, ?, ?, ?, ?);
        """

        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(
            database,
            query,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            print("❌ Impossible de préparer l'événement")
            return
        }

        defer {
            sqlite3_finalize(statement)
        }

        sqlite3_bind_int64(
            statement,
            1,
            snapshotID
        )

        sqlite3_bind_double(
            statement,
            2,
            timestamp.timeIntervalSince1970
        )

        event.type.withCString { pointer in
            _ = sqlite3_bind_text(
                statement,
                3,
                pointer,
                -1,
                sqliteTransient
            )
        }

        event.severity.withCString { pointer in
            _ = sqlite3_bind_text(
                statement,
                4,
                pointer,
                -1,
                sqliteTransient
            )
        }

        sqlite3_bind_double(
            statement,
            5,
            event.value
        )

        event.message.withCString { pointer in
            _ = sqlite3_bind_text(
                statement,
                6,
                pointer,
                -1,
                sqliteTransient
            )
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            print("❌ Impossible d'enregistrer l'événement")
            return
        }

        print("⚠️ Event saved to SQLite: \(event.type)")
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

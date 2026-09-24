import Foundation
import SQLite3

final class Database {

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

        if sqlite3_open(path, &database) != SQLITE_OK {
            print("❌ Impossible d'ouvrir SQLite")
        } else {
            print("SQLite database:")
            print(path)
        }

        createTables()
    }

    deinit {
        sqlite3_close(database)
    }

    // MARK: - Tables

    private func createTables() {

        let systemQuery = """
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
        """

        let processQuery = """
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
        """

        let eventQuery = """
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
        """

        let diskProcessEventQuery = """
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
        """

        let diskProcessEventIndex = """
        CREATE INDEX IF NOT EXISTS idx_disk_process_events_snapshot_id
        ON disk_process_events(snapshot_id);
        """

        execute(query: systemQuery)
        execute(query: processQuery)
        execute(query: eventQuery)
        execute(query: diskProcessEventQuery)
        execute(query: diskProcessEventIndex)

        // Additive migrations: add disk I/O columns to existing databases.
        // ALTER TABLE ... ADD COLUMN is idempotent when the column already
        // exists in a freshly-created table; we silence the "duplicate column"
        // error intentionally.
        execute(query: """
            ALTER TABLE process_samples
            ADD COLUMN disk_read_bytes INTEGER NOT NULL DEFAULT 0;
        """)
        execute(query: """
            ALTER TABLE process_samples
            ADD COLUMN disk_write_bytes INTEGER NOT NULL DEFAULT 0;
        """)

        print("Database schema ready")
    }
    
    private func execute(query: String) {

        var errorMessage: UnsafeMutablePointer<CChar>?

        let result = sqlite3_exec(
            database,
            query,
            nil,
            nil,
            &errorMessage
        )

        if result != SQLITE_OK {

            if let errorMessage {
                let message = String(
                    cString: errorMessage
                )

                print("❌ SQLite error: \(message)")

                sqlite3_free(errorMessage)
            }
        }
    }

    // MARK: - Save snapshot

    @discardableResult
    func save(snapshot: SystemSnapshot) -> Int64? {

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

        guard sqlite3_prepare_v2(
            database,
            query,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {

            print("❌ Impossible de préparer l'insertion du snapshot")
            return nil
        }

        defer {
            sqlite3_finalize(statement)
        }

        sqlite3_bind_double(
            statement,
            1,
            snapshot.timestamp.timeIntervalSince1970
        )

        sqlite3_bind_double(
            statement,
            2,
            snapshot.cpu
        )

        sqlite3_bind_double(
            statement,
            3,
            snapshot.memory
        )

        sqlite3_bind_double(
            statement,
            4,
            snapshot.diskRead
        )

        sqlite3_bind_double(
            statement,
            5,
            snapshot.diskWrite
        )

        sqlite3_bind_double(
            statement,
            6,
            snapshot.networkIn
        )

        sqlite3_bind_double(
            statement,
            7,
            snapshot.networkOut
        )

        guard sqlite3_step(statement) == SQLITE_DONE else {
            print("❌ Impossible d'enregistrer le snapshot")
            return nil
        }

        let snapshotID = sqlite3_last_insert_rowid(database)

        for process in snapshot.processes {
            saveProcess(
                process,
                snapshotID: snapshotID,
                timestamp: snapshot.timestamp
            )
        }

        print(
            "Snapshot saved to SQLite (\(snapshot.processes.count) processes)"
        )

        return snapshotID
    }

    // MARK: - Save process

    private func saveProcess(
        _ process: ProcessSnapshot,
        snapshotID: Int64,
        timestamp: Date
    ) {

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

        guard sqlite3_prepare_v2(
            database,
            query,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            print("❌ Impossible de préparer le processus")
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

        sqlite3_bind_int(
            statement,
            3,
            process.pid
        )

        sqlite3_bind_double(
            statement,
            5,
            process.cpuUsage
        )

        sqlite3_bind_int64(
            statement,
            6,
            Int64(process.memoryBytes)
        )

        sqlite3_bind_int64(
            statement,
            7,
            Int64(process.diskReadBytes)
        )

        sqlite3_bind_int64(
            statement,
            8,
            Int64(process.diskWriteBytes)
        )

        process.name.withCString { namePointer in
            sqlite3_bind_text(
                statement,
                4,
                namePointer,
                -1,
                nil
            )
            _ = sqlite3_step(statement)
        }
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
            sqlite3_bind_text(
                statement,
                3,
                pointer,
                -1,
                nil
            )
        }

        event.severity.withCString { pointer in
            sqlite3_bind_text(
                statement,
                4,
                pointer,
                -1,
                nil
            )
        }

        sqlite3_bind_double(
            statement,
            5,
            event.value
        )

        event.message.withCString { pointer in
            sqlite3_bind_text(
                statement,
                6,
                pointer,
                -1,
                nil
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

        guard sqlite3_prepare_v2(
            database,
            query,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            print("❌ Impossible de préparer l'insertion du disk_process_event")
            return 0
        }

        defer {
            sqlite3_finalize(statement)
        }

        execute(query: "BEGIN TRANSACTION;")
        var insertedCount = 0

        for event in events {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)

            if let snapshotID {
                sqlite3_bind_int64(statement, 1, snapshotID)
            } else {
                sqlite3_bind_null(statement, 1)
            }

            sqlite3_bind_double(
                statement,
                2,
                event.timestamp.timeIntervalSince1970
            )

            sqlite3_bind_int64(
                statement,
                4,
                Int64(event.bytes)
            )

            sqlite3_bind_int(
                statement,
                6,
                event.pid
            )

            event.operation.withCString { opPointer in
                sqlite3_bind_text(
                    statement,
                    3,
                    opPointer,
                    -1,
                    nil
                )

                event.processName.withCString { namePointer in
                    sqlite3_bind_text(
                        statement,
                        5,
                        namePointer,
                        -1,
                        nil
                    )

                    if sqlite3_step(statement) == SQLITE_DONE {
                        insertedCount += 1
                    } else {
                        print("❌ Impossible d'enregistrer le disk_process_event")
                    }
                }
            }
        }

        execute(query: "COMMIT;")
        return insertedCount
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

import Foundation
import SQLite3

final class Database {

    private var database: OpaquePointer?

    init() {

        let fileManager = FileManager.default

        let projectRoot = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let databaseDirectory = projectRoot
            .appendingPathComponent("data/database", isDirectory: true)

        try? fileManager.createDirectory(
            at: databaseDirectory,
            withIntermediateDirectories: true
        )

        let databaseURL = databaseDirectory
            .appendingPathComponent("mac_detective.sqlite")

        if sqlite3_open(databaseURL.path, &database) != SQLITE_OK {
            print("❌ Impossible d'ouvrir SQLite")
        } else {
            print("SQLite database:")
            print(databaseURL.path)
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

        execute(query: systemQuery)
        execute(query: processQuery)
        execute(query: eventQuery)

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
            memory
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

        process.name.withCString { namePointer in
            sqlite3_bind_text(
                statement,
                4,
                namePointer,
                -1,
                nil
            )
        }

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

        _ = sqlite3_step(statement)
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
        SELECT pid, name, cpu, memory
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

            processes.append(
                ProcessSnapshot(
                    pid: pid,
                    name: name,
                    cpuUsage: cpu,
                    memoryBytes: memory,
                    diskReadBytes: 0,
                    diskWriteBytes: 0
                )
            )
        }

        return processes
    }
}

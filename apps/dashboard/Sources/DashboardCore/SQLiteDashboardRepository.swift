import Foundation
import SQLite3

private let dashboardSQLiteTransient = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)

public final class SQLiteDashboardRepository: DashboardRepository, @unchecked Sendable {
    private let configuration: DashboardRepositoryConfiguration
    private let queue = DispatchQueue(label: "com.personal-os.dashboard.sqlite")
    private var connection: OpaquePointer?

    public init(configuration: DashboardRepositoryConfiguration) throws {
        self.configuration = configuration

        guard FileManager.default.fileExists(atPath: configuration.databaseURL.path) else {
            throw DashboardRepositoryError.databaseMissing(
                path: configuration.databaseURL.path
            )
        }

        var handle: OpaquePointer?
        let result = sqlite3_open_v2(
            configuration.databaseURL.path,
            &handle,
            SQLITE_OPEN_READONLY,
            nil
        )

        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) }
                ?? "unable to open database"
            if let handle {
                sqlite3_close_v2(handle)
            }
            throw DashboardRepositoryError.sqlite(message: message)
        }

        connection = handle

        do {
            try configureConnection()
            try validateSchema()
        } catch {
            sqlite3_close_v2(handle)
            connection = nil
            throw error
        }
    }

    deinit {
        if let connection {
            sqlite3_close_v2(connection)
        }
    }

    public func fetchDashboard(
        range: DashboardTimeRange
    ) async throws -> DashboardSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    continuation.resume(
                        returning: try fetchDashboardSynchronously(range: range)
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func close() {
        queue.sync {
            guard let connection else {
                return
            }
            sqlite3_close_v2(connection)
            self.connection = nil
        }
    }

    private func configureConnection() throws {
        guard let connection else {
            throw DashboardRepositoryError.sqlite(message: "database is not open")
        }
        sqlite3_busy_timeout(connection, 2_500)

        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(
            connection,
            "PRAGMA query_only=ON;",
            nil,
            nil,
            &errorMessage
        )
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(connection))
            sqlite3_free(errorMessage)
            throw DashboardRepositoryError.sqlite(message: message)
        }
    }

    private func validateSchema() throws {
        let version = try scalarInt("PRAGMA user_version;")
        guard version == DashboardRepositoryConfiguration.currentSchemaVersion else {
            throw DashboardRepositoryError.schemaMismatch(
                expected: DashboardRepositoryConfiguration.currentSchemaVersion,
                actual: version
            )
        }

        let requiredTables = [
            "system_samples",
            "process_samples",
            "disk_process_events",
            "events",
            "hourly_system_stats",
            "daily_system_stats",
            "hourly_process_stats",
            "daily_process_stats"
        ]
        let placeholders = Array(repeating: "?", count: requiredTables.count).joined(separator: ",")
        let query = """
            SELECT COUNT(*)
            FROM sqlite_master
            WHERE type = 'table' AND name IN (\(placeholders));
            """

        let count = try withStatement(query) { statement in
            try bind(requiredTables, to: statement, startingAt: 1)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw DashboardRepositoryError.sqlite(
                    message: "unable to inspect SQLite schema"
                )
            }
            return Int(sqlite3_column_int64(statement, 0))
        }

        guard count == requiredTables.count else {
            throw DashboardRepositoryError.invalidData(
                message: "required SQLite tables are missing"
            )
        }
    }

    private func fetchDashboardSynchronously(
        range: DashboardTimeRange
    ) throws -> DashboardSnapshot {
        let now = configuration.now()
        let start = now.addingTimeInterval(-range.duration)
        let latest = try fetchLatestSample()
        let summary = try fetchMetricSummary(
            range: range,
            start: start,
            end: now,
            latest: latest
        )
        let history = try fetchHistory(
            range: range,
            start: start,
            end: now
        )
        let rankings = try fetchRankings(latest: latest, limit: 5)
        let events = try fetchEvents(limit: 50)
        let runtime = readRuntimeStatus(now: now)

        return DashboardSnapshot(
            generatedAt: now,
            range: range,
            overview: DashboardOverview(
                latestTimestamp: latest?.timestamp,
                cpu: summary.cpu,
                memory: summary.memory,
                diskRead: summary.diskRead,
                diskWrite: summary.diskWrite,
                networkIn: summary.networkIn,
                networkOut: summary.networkOut,
                droppedEvents: latest.map { max(0, $0.droppedEvents) }
            ),
            history: history,
            rankings: rankings,
            events: events,
            runtime: runtime,
            fsUsage: runtime.payload?.fsUsage
        )
    }

    private func fetchLatestSample() throws -> DashboardSample? {
        try withStatement(
            """
            SELECT id, timestamp, cpu, memory, disk_read, disk_write,
                   network_in, network_out, dropped_events
            FROM system_samples
            ORDER BY timestamp DESC
            LIMIT 1;
            """
        ) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            return DashboardSample(
                id: Int64(sqlite3_column_int64(statement, 0)),
                timestamp: Date(
                    timeIntervalSince1970: sqlite3_column_double(statement, 1)
                ),
                cpu: sqlite3_column_double(statement, 2),
                memory: sqlite3_column_double(statement, 3),
                diskRead: sqlite3_column_double(statement, 4),
                diskWrite: sqlite3_column_double(statement, 5),
                networkIn: sqlite3_column_double(statement, 6),
                networkOut: sqlite3_column_double(statement, 7),
                droppedEvents: Int(sqlite3_column_int64(statement, 8))
            )
        }
    }

    private func fetchMetricSummary(
        range: DashboardTimeRange,
        start: Date,
        end: Date,
        latest: DashboardSample?
    ) throws -> DashboardMetricSummary {
        if range.usesHourlyAggregates,
           let aggregate = try fetchHourlySummary(start: start, end: end) {
            return summary(
                latest: latest,
                aggregate: aggregate
            )
        }

        let detail = try fetchDetailedSummary(start: start, end: end)
        return summary(latest: latest, aggregate: detail)
    }

    private func fetchDetailedSummary(
        start: Date,
        end: Date
    ) throws -> AggregateSummary {
        try withStatement(
            """
            SELECT COUNT(*), AVG(cpu), MAX(cpu), AVG(memory), MAX(memory),
                   AVG(disk_read), MAX(disk_read), AVG(disk_write), MAX(disk_write),
                   AVG(network_in), MAX(network_in), AVG(network_out), MAX(network_out)
            FROM system_samples
            WHERE timestamp >= ? AND timestamp <= ?;
            """
        ) { statement in
            try bind(start.timeIntervalSince1970, to: statement, at: 1)
            try bind(end.timeIntervalSince1970, to: statement, at: 2)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw DashboardRepositoryError.sqlite(
                    message: "unable to read system summary"
                )
            }
            let count = Int(sqlite3_column_int64(statement, 0))
            guard count > 0 else {
                return AggregateSummary(count: 0)
            }
            return AggregateSummary(
                count: count,
                cpuAverage: sqlite3_column_double(statement, 1),
                cpuMaximum: sqlite3_column_double(statement, 2),
                memoryAverage: sqlite3_column_double(statement, 3),
                memoryMaximum: sqlite3_column_double(statement, 4),
                diskReadAverage: sqlite3_column_double(statement, 5),
                diskReadMaximum: sqlite3_column_double(statement, 6),
                diskWriteAverage: sqlite3_column_double(statement, 7),
                diskWriteMaximum: sqlite3_column_double(statement, 8),
                networkInAverage: sqlite3_column_double(statement, 9),
                networkInMaximum: sqlite3_column_double(statement, 10),
                networkOutAverage: sqlite3_column_double(statement, 11),
                networkOutMaximum: sqlite3_column_double(statement, 12)
            )
        }
    }

    private func fetchHourlySummary(
        start: Date,
        end: Date
    ) throws -> AggregateSummary? {
        let summary: AggregateSummary? = try withStatement(
            """
            SELECT COUNT(*), AVG(cpu_avg), MAX(cpu_max),
                   AVG(memory_avg), MAX(memory_max),
                   AVG(disk_read_avg), MAX(disk_read_max),
                   AVG(disk_write_avg), MAX(disk_write_max),
                   AVG(network_in_avg), MAX(network_in_max),
                   AVG(network_out_avg), MAX(network_out_max)
            FROM hourly_system_stats
            WHERE bucket_start >= ? AND bucket_start <= ?;
            """
        ) { statement in
            try bind(start.timeIntervalSince1970, to: statement, at: 1)
            try bind(end.timeIntervalSince1970, to: statement, at: 2)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw DashboardRepositoryError.sqlite(
                    message: "unable to read hourly summary"
                )
            }
            let count = Int(sqlite3_column_int64(statement, 0))
            guard count > 0 else {
                return nil
            }
            return AggregateSummary(
                count: count,
                cpuAverage: sqlite3_column_double(statement, 1),
                cpuMaximum: sqlite3_column_double(statement, 2),
                memoryAverage: sqlite3_column_double(statement, 3),
                memoryMaximum: sqlite3_column_double(statement, 4),
                diskReadAverage: sqlite3_column_double(statement, 5),
                diskReadMaximum: sqlite3_column_double(statement, 6),
                diskWriteAverage: sqlite3_column_double(statement, 7),
                diskWriteMaximum: sqlite3_column_double(statement, 8),
                networkInAverage: sqlite3_column_double(statement, 9),
                networkInMaximum: sqlite3_column_double(statement, 10),
                networkOutAverage: sqlite3_column_double(statement, 11),
                networkOutMaximum: sqlite3_column_double(statement, 12)
            )
        }
        return summary
    }

    private func summary(
        latest: DashboardSample?,
        aggregate: AggregateSummary
    ) -> DashboardMetricSummary {
        guard aggregate.count > 0 else {
            return DashboardMetricSummary(
                cpu: MetricSummary(current: latest?.cpu),
                memory: MetricSummary(current: latest?.memory),
                diskRead: MetricSummary(current: latest?.diskRead),
                diskWrite: MetricSummary(current: latest?.diskWrite),
                networkIn: MetricSummary(current: latest?.networkIn),
                networkOut: MetricSummary(current: latest?.networkOut)
            )
        }

        return DashboardMetricSummary(
            cpu: MetricSummary(
                current: latest?.cpu,
                average: aggregate.cpuAverage,
                maximum: aggregate.cpuMaximum
            ),
            memory: MetricSummary(
                current: latest?.memory,
                average: aggregate.memoryAverage,
                maximum: aggregate.memoryMaximum
            ),
            diskRead: MetricSummary(
                current: latest?.diskRead,
                average: aggregate.diskReadAverage,
                maximum: aggregate.diskReadMaximum
            ),
            diskWrite: MetricSummary(
                current: latest?.diskWrite,
                average: aggregate.diskWriteAverage,
                maximum: aggregate.diskWriteMaximum
            ),
            networkIn: MetricSummary(
                current: latest?.networkIn,
                average: aggregate.networkInAverage,
                maximum: aggregate.networkInMaximum
            ),
            networkOut: MetricSummary(
                current: latest?.networkOut,
                average: aggregate.networkOutAverage,
                maximum: aggregate.networkOutMaximum
            )
        )
    }

    private func fetchHistory(
        range: DashboardTimeRange,
        start: Date,
        end: Date
    ) throws -> [MetricPoint] {
        if range.usesHourlyAggregates {
            let aggregatePoints = try fetchHourlyHistory(start: start, end: end)
            if !aggregatePoints.isEmpty {
                return aggregatePoints
            }
        }
        return try fetchDetailedHistory(start: start, end: end)
    }

    private func fetchHourlyHistory(
        start: Date,
        end: Date
    ) throws -> [MetricPoint] {
        try withStatement(
            """
            SELECT bucket_start, cpu_avg, memory_avg, disk_read_avg,
                   disk_write_avg, network_in_avg, network_out_avg
            FROM hourly_system_stats
            WHERE bucket_start >= ? AND bucket_start <= ?
            ORDER BY bucket_start ASC;
            """
        ) { statement in
            try bind(start.timeIntervalSince1970, to: statement, at: 1)
            try bind(end.timeIntervalSince1970, to: statement, at: 2)
            var points: [MetricPoint] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                points.append(
                    MetricPoint(
                        timestamp: dateColumn(statement, 0),
                        cpu: sqlite3_column_double(statement, 1),
                        memory: sqlite3_column_double(statement, 2),
                        diskRead: sqlite3_column_double(statement, 3),
                        diskWrite: sqlite3_column_double(statement, 4),
                        networkIn: sqlite3_column_double(statement, 5),
                        networkOut: sqlite3_column_double(statement, 6),
                        isAggregate: true
                    )
                )
            }
            return points
        }
    }

    private func fetchDetailedHistory(
        start: Date,
        end: Date
    ) throws -> [MetricPoint] {
        try withStatement(
            """
            SELECT timestamp, cpu, memory, disk_read, disk_write,
                   network_in, network_out
            FROM system_samples
            WHERE timestamp >= ? AND timestamp <= ?
            ORDER BY timestamp ASC
            LIMIT 5000;
            """
        ) { statement in
            try bind(start.timeIntervalSince1970, to: statement, at: 1)
            try bind(end.timeIntervalSince1970, to: statement, at: 2)
            var points: [MetricPoint] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                points.append(
                    MetricPoint(
                        timestamp: dateColumn(statement, 0),
                        cpu: sqlite3_column_double(statement, 1),
                        memory: sqlite3_column_double(statement, 2),
                        diskRead: sqlite3_column_double(statement, 3),
                        diskWrite: sqlite3_column_double(statement, 4),
                        networkIn: sqlite3_column_double(statement, 5),
                        networkOut: sqlite3_column_double(statement, 6)
                    )
                )
            }
            return points
        }
    }

    private func fetchRankings(
        latest: DashboardSample?,
        limit: Int
    ) throws -> ProcessRankings {
        guard let latest else {
            return ProcessRankings()
        }

        let cpu = try fetchProcessRows(
            snapshotID: latest.id,
            order: "cpu DESC",
            limit: limit
        ).map {
            ProcessRanking(
                pid: $0.pid,
                name: $0.name,
                cpuPercent: $0.cpu,
                memoryBytes: $0.memoryBytes
            )
        }
        let memory = try fetchProcessRows(
            snapshotID: latest.id,
            order: "memory DESC",
            limit: limit
        ).map {
            ProcessRanking(
                pid: $0.pid,
                name: $0.name,
                cpuPercent: $0.cpu,
                memoryBytes: $0.memoryBytes
            )
        }
        let previousTimestamp = try fetchPreviousTimestamp(before: latest.timestamp)
        let elapsed = previousTimestamp.map {
            latest.timestamp.timeIntervalSince($0)
        }
        let disk = try fetchDiskRankings(
            snapshotID: latest.id,
            limit: limit,
            elapsed: elapsed
        )
        return ProcessRankings(cpu: cpu, memory: memory, disk: disk)
    }

    private func fetchProcessRows(
        snapshotID: Int64,
        order: String,
        limit: Int
    ) throws -> [ProcessRow] {
        try withStatement(
            """
            SELECT pid, name, cpu, memory
            FROM process_samples
            WHERE snapshot_id = ?
            ORDER BY \(order), pid ASC
            LIMIT ?;
            """
        ) { statement in
            try bind(snapshotID, to: statement, at: 1)
            try bind(Int64(limit), to: statement, at: 2)
            var rows: [ProcessRow] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(
                    ProcessRow(
                        pid: Int32(sqlite3_column_int(statement, 0)),
                        name: stringColumn(statement, 1) ?? "Unknown",
                        cpu: sqlite3_column_double(statement, 2),
                        memoryBytes: uint64Column(statement, 3)
                    )
                )
            }
            return rows
        }
    }

    private func fetchPreviousTimestamp(before timestamp: Date) throws -> Date? {
        try withStatement(
            """
            SELECT timestamp
            FROM system_samples
            WHERE timestamp < ?
            ORDER BY timestamp DESC
            LIMIT 1;
            """
        ) { statement in
            try bind(timestamp.timeIntervalSince1970, to: statement, at: 1)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            return dateColumn(statement, 0)
        }
    }

    private func fetchDiskRankings(
        snapshotID: Int64,
        limit: Int,
        elapsed: TimeInterval?
    ) throws -> [ProcessRanking] {
        try withStatement(
            """
            SELECT process_name, pid,
                   COALESCE(SUM(CASE WHEN UPPER(operation) LIKE 'R%' THEN bytes ELSE 0 END), 0),
                   COALESCE(SUM(CASE WHEN UPPER(operation) LIKE 'W%' THEN bytes ELSE 0 END), 0),
                   COALESCE(SUM(bytes), 0)
            FROM disk_process_events
            WHERE snapshot_id = ?
            GROUP BY process_name, pid
            ORDER BY 5 DESC, process_name ASC, pid ASC
            LIMIT ?;
            """
        ) { statement in
            try bind(snapshotID, to: statement, at: 1)
            try bind(Int64(limit), to: statement, at: 2)
            var rankings: [ProcessRanking] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let readBytes = uint64Column(statement, 2)
                let writeBytes = uint64Column(statement, 3)
                let totalBytes = uint64Column(statement, 4)
                let readRate = elapsed.flatMap { value -> Double? in
                    value > 0 ? Double(readBytes) / value : nil
                }
                let writeRate = elapsed.flatMap { value -> Double? in
                    value > 0 ? Double(writeBytes) / value : nil
                }
                rankings.append(
                    ProcessRanking(
                        pid: Int32(sqlite3_column_int(statement, 1)),
                        name: stringColumn(statement, 0) ?? "Unknown",
                        diskReadBytesPerSecond: readRate,
                        diskWriteBytesPerSecond: writeRate,
                        diskTotalBytes: totalBytes
                    )
                )
            }
            return rankings
        }
    }

    private func fetchEvents(limit: Int) throws -> [DashboardEvent] {
        try withStatement(
            """
            SELECT id, timestamp, type, severity, value, message, snapshot_id
            FROM events
            ORDER BY timestamp DESC, id DESC
            LIMIT ?;
            """
        ) { statement in
            try bind(Int64(limit), to: statement, at: 1)
            var events: [DashboardEvent] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let snapshotID: Int64?
                if sqlite3_column_type(statement, 6) == SQLITE_NULL {
                    snapshotID = nil
                } else {
                    snapshotID = sqlite3_column_int64(statement, 6)
                }
                events.append(
                    DashboardEvent(
                        id: sqlite3_column_int64(statement, 0),
                        timestamp: dateColumn(statement, 1),
                        type: stringColumn(statement, 2) ?? "UNKNOWN",
                        severity: stringColumn(statement, 3) ?? "info",
                        value: sqlite3_column_double(statement, 4),
                        message: stringColumn(statement, 5) ?? "",
                        snapshotID: snapshotID
                    )
                )
            }
            return events
        }
    }

    private func readRuntimeStatus(now: Date) -> RuntimeObservation {
        guard FileManager.default.fileExists(
            atPath: configuration.runtimeStatusURL.path
        ) else {
            return .unknown(reason: "Runtime status file unavailable")
        }

        do {
            let data = try Data(contentsOf: configuration.runtimeStatusURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(
                RuntimeStatusPayload.self,
                from: data
            )
            guard payload.version == 1 else {
                return .unknown(reason: "Unsupported runtime status version")
            }
            if now.timeIntervalSince(payload.updatedAt) > configuration.staleAfter {
                return .stale(payload)
            }
            return .current(payload)
        } catch {
            return .unknown(reason: "Runtime status unavailable")
        }
    }

    private func scalarInt(_ query: String) throws -> Int {
        try withStatement(query) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw DashboardRepositoryError.sqlite(
                    message: "unable to read scalar value"
                )
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    private func withStatement<T>(
        _ query: String,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        guard let connection else {
            throw DashboardRepositoryError.sqlite(
                message: "database is not open"
            )
        }

        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(
            connection,
            query,
            -1,
            &statement,
            nil
        )
        guard result == SQLITE_OK, let statement else {
            throw DashboardRepositoryError.sqlite(
                message: String(cString: sqlite3_errmsg(connection))
            )
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func bind(
        _ values: [String],
        to statement: OpaquePointer,
        startingAt start: Int32
    ) throws {
        for (offset, value) in values.enumerated() {
            let result = sqlite3_bind_text(
                statement,
                start + Int32(offset),
                value,
                -1,
                dashboardSQLiteTransient
            )
            guard result == SQLITE_OK else {
                throw DashboardRepositoryError.sqlite(
                    message: "unable to bind text"
                )
            }
        }
    }

    private func bind(
        _ value: Int64,
        to statement: OpaquePointer,
        at index: Int32
    ) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
            throw DashboardRepositoryError.sqlite(message: "unable to bind integer")
        }
    }

    private func bind(
        _ value: Double,
        to statement: OpaquePointer,
        at index: Int32
    ) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
            throw DashboardRepositoryError.sqlite(message: "unable to bind number")
        }
    }

    private func dateColumn(
        _ statement: OpaquePointer,
        _ index: Int32
    ) -> Date {
        Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }

    private func stringColumn(
        _ statement: OpaquePointer,
        _ index: Int32
    ) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: pointer)
    }

    private func uint64Column(
        _ statement: OpaquePointer,
        _ index: Int32
    ) -> UInt64 {
        let value = sqlite3_column_int64(statement, index)
        return value > 0 ? UInt64(value) : 0
    }
}

private struct DashboardSample {
    let id: Int64
    let timestamp: Date
    let cpu: Double
    let memory: Double
    let diskRead: Double
    let diskWrite: Double
    let networkIn: Double
    let networkOut: Double
    let droppedEvents: Int
}

private struct AggregateSummary {
    let count: Int
    var cpuAverage: Double?
    var cpuMaximum: Double?
    var memoryAverage: Double?
    var memoryMaximum: Double?
    var diskReadAverage: Double?
    var diskReadMaximum: Double?
    var diskWriteAverage: Double?
    var diskWriteMaximum: Double?
    var networkInAverage: Double?
    var networkInMaximum: Double?
    var networkOutAverage: Double?
    var networkOutMaximum: Double?

    init(
        count: Int,
        cpuAverage: Double? = nil,
        cpuMaximum: Double? = nil,
        memoryAverage: Double? = nil,
        memoryMaximum: Double? = nil,
        diskReadAverage: Double? = nil,
        diskReadMaximum: Double? = nil,
        diskWriteAverage: Double? = nil,
        diskWriteMaximum: Double? = nil,
        networkInAverage: Double? = nil,
        networkInMaximum: Double? = nil,
        networkOutAverage: Double? = nil,
        networkOutMaximum: Double? = nil
    ) {
        self.count = count
        self.cpuAverage = cpuAverage
        self.cpuMaximum = cpuMaximum
        self.memoryAverage = memoryAverage
        self.memoryMaximum = memoryMaximum
        self.diskReadAverage = diskReadAverage
        self.diskReadMaximum = diskReadMaximum
        self.diskWriteAverage = diskWriteAverage
        self.diskWriteMaximum = diskWriteMaximum
        self.networkInAverage = networkInAverage
        self.networkInMaximum = networkInMaximum
        self.networkOutAverage = networkOutAverage
        self.networkOutMaximum = networkOutMaximum
    }
}

private struct DashboardMetricSummary {
    let cpu: MetricSummary
    let memory: MetricSummary
    let diskRead: MetricSummary
    let diskWrite: MetricSummary
    let networkIn: MetricSummary
    let networkOut: MetricSummary
}

private struct ProcessRow {
    let pid: Int32
    let name: String
    let cpu: Double
    let memoryBytes: UInt64
}

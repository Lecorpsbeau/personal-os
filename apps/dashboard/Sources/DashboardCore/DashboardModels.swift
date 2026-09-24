import Foundation

public enum DashboardTimeRange: String, CaseIterable, Identifiable, Sendable {
    case fifteenMinutes
    case oneHour
    case oneDay

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fifteenMinutes:
            return "15 min"
        case .oneHour:
            return "1 heure"
        case .oneDay:
            return "24 heures"
        }
    }

    public var duration: TimeInterval {
        switch self {
        case .fifteenMinutes:
            return 15 * 60
        case .oneHour:
            return 60 * 60
        case .oneDay:
            return 24 * 60 * 60
        }
    }

    public var usesHourlyAggregates: Bool {
        self == .oneDay
    }
}

public enum DashboardSection: String, CaseIterable, Identifiable, Sendable {
    case overview
    case history
    case processes
    case events
    case diagnostics

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview:
            return "Overview"
        case .history:
            return "History"
        case .processes:
            return "Processes"
        case .events:
            return "Events"
        case .diagnostics:
            return "Diagnostics"
        }
    }
}

public struct MetricSummary: Equatable, Sendable {
    public let current: Double?
    public let average: Double?
    public let maximum: Double?

    public init(
        current: Double? = nil,
        average: Double? = nil,
        maximum: Double? = nil
    ) {
        self.current = current
        self.average = average
        self.maximum = maximum
    }

    public static let noData = MetricSummary()

    public var hasData: Bool {
        current != nil || average != nil || maximum != nil
    }
}

public struct DashboardOverview: Equatable, Sendable {
    public let latestTimestamp: Date?
    public let cpu: MetricSummary
    public let memory: MetricSummary
    public let diskRead: MetricSummary
    public let diskWrite: MetricSummary
    public let networkIn: MetricSummary
    public let networkOut: MetricSummary
    public let droppedEvents: Int?

    public init(
        latestTimestamp: Date?,
        cpu: MetricSummary,
        memory: MetricSummary,
        diskRead: MetricSummary,
        diskWrite: MetricSummary,
        networkIn: MetricSummary,
        networkOut: MetricSummary,
        droppedEvents: Int?
    ) {
        self.latestTimestamp = latestTimestamp
        self.cpu = cpu
        self.memory = memory
        self.diskRead = diskRead
        self.diskWrite = diskWrite
        self.networkIn = networkIn
        self.networkOut = networkOut
        self.droppedEvents = droppedEvents
    }

    public static let noData = DashboardOverview(
        latestTimestamp: nil,
        cpu: .noData,
        memory: .noData,
        diskRead: .noData,
        diskWrite: .noData,
        networkIn: .noData,
        networkOut: .noData,
        droppedEvents: nil
    )
}

public struct MetricPoint: Identifiable, Equatable, Sendable {
    public let timestamp: Date
    public let cpu: Double
    public let memory: Double
    public let diskRead: Double
    public let diskWrite: Double
    public let networkIn: Double
    public let networkOut: Double
    public let isAggregate: Bool

    public var id: Date { timestamp }

    public init(
        timestamp: Date,
        cpu: Double,
        memory: Double,
        diskRead: Double,
        diskWrite: Double,
        networkIn: Double,
        networkOut: Double,
        isAggregate: Bool = false
    ) {
        self.timestamp = timestamp
        self.cpu = cpu
        self.memory = memory
        self.diskRead = diskRead
        self.diskWrite = diskWrite
        self.networkIn = networkIn
        self.networkOut = networkOut
        self.isAggregate = isAggregate
    }
}

public struct ProcessRanking: Identifiable, Equatable, Sendable {
    public let pid: Int32
    public let name: String
    public let cpuPercent: Double?
    public let memoryBytes: UInt64?
    public let diskReadBytesPerSecond: Double?
    public let diskWriteBytesPerSecond: Double?
    public let diskTotalBytes: UInt64?

    public var id: String {
        "\(pid)-\(name)"
    }

    public init(
        pid: Int32,
        name: String,
        cpuPercent: Double? = nil,
        memoryBytes: UInt64? = nil,
        diskReadBytesPerSecond: Double? = nil,
        diskWriteBytesPerSecond: Double? = nil,
        diskTotalBytes: UInt64? = nil
    ) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
        self.diskTotalBytes = diskTotalBytes
    }
}

public struct ProcessRankings: Equatable, Sendable {
    public let cpu: [ProcessRanking]
    public let memory: [ProcessRanking]
    public let disk: [ProcessRanking]

    public init(
        cpu: [ProcessRanking] = [],
        memory: [ProcessRanking] = [],
        disk: [ProcessRanking] = []
    ) {
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
    }
}

public struct DashboardEvent: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let timestamp: Date
    public let type: String
    public let severity: String
    public let value: Double
    public let message: String
    public let snapshotID: Int64?

    public init(
        id: Int64,
        timestamp: Date,
        type: String,
        severity: String,
        value: Double,
        message: String,
        snapshotID: Int64?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.severity = severity
        self.value = value
        self.message = message
        self.snapshotID = snapshotID
    }
}

public struct RuntimeStatusPayload: Codable, Equatable, Sendable {
    public let version: Int
    public let state: String
    public let updatedAt: Date
    public let cyclesExecuted: Int
    public let lastCycleAt: Date?
    public let lastSuccessfulPersistenceAt: Date?
    public let lastMaintenanceAt: Date?
    public let fsUsage: RuntimeFSUsageStatusPayload?

    public enum CodingKeys: String, CodingKey {
        case version
        case state
        case updatedAt = "updated_at"
        case cyclesExecuted = "cycles_executed"
        case lastCycleAt = "last_cycle_at"
        case lastSuccessfulPersistenceAt = "last_successful_persistence_at"
        case lastMaintenanceAt = "last_maintenance_at"
        case fsUsage = "fs_usage"
    }

    public init(
        version: Int,
        state: String,
        updatedAt: Date,
        cyclesExecuted: Int,
        lastCycleAt: Date?,
        lastSuccessfulPersistenceAt: Date?,
        lastMaintenanceAt: Date?,
        fsUsage: RuntimeFSUsageStatusPayload?
    ) {
        self.version = version
        self.state = state
        self.updatedAt = updatedAt
        self.cyclesExecuted = cyclesExecuted
        self.lastCycleAt = lastCycleAt
        self.lastSuccessfulPersistenceAt = lastSuccessfulPersistenceAt
        self.lastMaintenanceAt = lastMaintenanceAt
        self.fsUsage = fsUsage
    }
}

public struct RuntimeFSUsageStatusPayload: Codable, Equatable, Sendable {
    public let state: String?
    public let diagnostic: String?
    public let permissionDenied: Bool?
    public let stderr: String?
    public let droppedEvents: Int?

    public enum CodingKeys: String, CodingKey {
        case state
        case diagnostic
        case permissionDenied = "permission_denied"
        case stderr
        case droppedEvents = "dropped_events"
    }

    public init(
        state: String? = nil,
        diagnostic: String? = nil,
        permissionDenied: Bool? = nil,
        stderr: String? = nil,
        droppedEvents: Int? = nil
    ) {
        self.state = state
        self.diagnostic = diagnostic
        self.permissionDenied = permissionDenied
        self.stderr = stderr
        self.droppedEvents = droppedEvents
    }
}

public enum RuntimeObservation: Equatable, Sendable {
    case unknown(reason: String)
    case stale(RuntimeStatusPayload)
    case current(RuntimeStatusPayload)

    public var payload: RuntimeStatusPayload? {
        switch self {
        case .unknown:
            return nil
        case .stale(let payload), .current(let payload):
            return payload
        }
    }

    public var isAvailable: Bool {
        if case .unknown = self {
            return false
        }
        return true
    }
}

public struct DashboardSnapshot: Equatable, Sendable {
    public let generatedAt: Date
    public let range: DashboardTimeRange
    public let overview: DashboardOverview
    public let history: [MetricPoint]
    public let rankings: ProcessRankings
    public let events: [DashboardEvent]
    public let runtime: RuntimeObservation
    public let fsUsage: RuntimeFSUsageStatusPayload?
    public let databasePath: String
    public let schemaVersion: Int?

    public init(
        generatedAt: Date,
        range: DashboardTimeRange,
        overview: DashboardOverview,
        history: [MetricPoint],
        rankings: ProcessRankings,
        events: [DashboardEvent],
        runtime: RuntimeObservation,
        fsUsage: RuntimeFSUsageStatusPayload?,
        databasePath: String = "",
        schemaVersion: Int? = nil
    ) {
        self.generatedAt = generatedAt
        self.range = range
        self.overview = overview
        self.history = history
        self.rankings = rankings
        self.events = events
        self.runtime = runtime
        self.fsUsage = fsUsage
        self.databasePath = databasePath
        self.schemaVersion = schemaVersion
    }
}

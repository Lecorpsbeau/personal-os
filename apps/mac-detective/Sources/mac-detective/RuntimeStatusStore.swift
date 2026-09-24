import Foundation

struct RuntimeStatusPayload: Codable, Equatable, Sendable {
    let version: Int
    let state: String
    let updatedAt: Date
    let cyclesExecuted: Int
    let lastCycleAt: Date?
    let lastSuccessfulPersistenceAt: Date?
    let lastMaintenanceAt: Date?
    let fsUsage: RuntimeFSUsageStatusPayload?

    enum CodingKeys: String, CodingKey {
        case version
        case state
        case updatedAt = "updated_at"
        case cyclesExecuted = "cycles_executed"
        case lastCycleAt = "last_cycle_at"
        case lastSuccessfulPersistenceAt = "last_successful_persistence_at"
        case lastMaintenanceAt = "last_maintenance_at"
        case fsUsage = "fs_usage"
    }
}

struct RuntimeFSUsageStatusPayload: Codable, Equatable, Sendable {
    let state: String?
    let diagnostic: String?
    let permissionDenied: Bool?
    let stderr: String?
    let droppedEvents: Int?

    enum CodingKeys: String, CodingKey {
        case state
        case diagnostic
        case permissionDenied = "permission_denied"
        case stderr
        case droppedEvents = "dropped_events"
    }
}

protocol RuntimeStatusReporting: AnyObject {
    func publish(_ status: RuntimeStatusPayload)
}

final class NoopRuntimeStatusReporter: RuntimeStatusReporting {
    func publish(_ status: RuntimeStatusPayload) {}
}

final class RuntimeStatusFileStore: RuntimeStatusReporting, @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var lastErrorDescription: String?

    init(url: URL) {
        self.url = url
    }

    func publish(_ status: RuntimeStatusPayload) {
        lock.lock()
        defer { lock.unlock() }

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(status)
            try data.write(to: url, options: [.atomic])
            lastErrorDescription = nil
        } catch {
            let message = "Runtime status write failed: \(error)"
            let shouldPrint = lastErrorDescription != message
            lastErrorDescription = message
            if shouldPrint {
                print("⚠️ \(message)")
            }
        }
    }
}

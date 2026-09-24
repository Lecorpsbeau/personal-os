import Foundation

public protocol DashboardRepository: Sendable {
    func fetchDashboard(range: DashboardTimeRange) async throws -> DashboardSnapshot
}

public enum DashboardRepositoryError: Error, Equatable, LocalizedError, Sendable {
    case databaseMissing(path: String)
    case schemaMismatch(expected: Int, actual: Int)
    case sqlite(message: String)
    case invalidData(message: String)

    public var errorDescription: String? {
        switch self {
        case .databaseMissing(let path):
            return "Database introuvable: \(path)"
        case .schemaMismatch(let expected, let actual):
            return "Schéma SQLite incompatible (version \(actual), version \(expected) attendue)"
        case .sqlite(let message):
            return "Erreur SQLite: \(message)"
        case .invalidData(let message):
            return "Données invalides: \(message)"
        }
    }
}

public struct DashboardRepositoryConfiguration: Sendable {
    public static let currentSchemaVersion = 4
    public static let defaultRuntimeStatusFilename = ".mac-detective-runtime-status.json"
    public static let defaultDatabaseFilename = "mac_detective.sqlite"

    public let databaseURL: URL
    public let runtimeStatusURL: URL
    public let staleAfter: TimeInterval
    public let now: @Sendable () -> Date

    public init(
        databaseURL: URL,
        runtimeStatusURL: URL? = nil,
        staleAfter: TimeInterval = 10,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.databaseURL = databaseURL
        self.runtimeStatusURL = runtimeStatusURL
            ?? databaseURL.deletingLastPathComponent()
                .appendingPathComponent(Self.defaultRuntimeStatusFilename)
        self.staleAfter = staleAfter
        self.now = now
    }

    public static func local(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> DashboardRepositoryConfiguration {
        if let databasePath = environment["MAC_DETECTIVE_DATABASE"] {
            let databaseURL = URL(fileURLWithPath: databasePath)
            let statusURL = environment["MAC_DETECTIVE_RUNTIME_STATUS"]
                .map { URL(fileURLWithPath: $0) }
            return DashboardRepositoryConfiguration(
                databaseURL: databaseURL,
                runtimeStatusURL: statusURL
            )
        }

        let currentDirectory = URL(
            fileURLWithPath: fileManager.currentDirectoryPath,
            isDirectory: true
        )
        var candidates: [URL] = [currentDirectory]

        if currentDirectory.lastPathComponent == "dashboard",
           currentDirectory.deletingLastPathComponent().lastPathComponent == "apps" {
            candidates.insert(
                currentDirectory.deletingLastPathComponent().deletingLastPathComponent(),
                at: 0
            )
        }

        var ancestor = currentDirectory
        for _ in 0..<5 {
            ancestor = ancestor.deletingLastPathComponent()
            candidates.append(ancestor)
        }

        let databaseDirectory = candidates
            .map { $0.appendingPathComponent("data/database", isDirectory: true) }
            .first { fileManager.fileExists(atPath: $0.appendingPathComponent(Self.defaultDatabaseFilename).path) }
            ?? candidates[0].appendingPathComponent("data/database", isDirectory: true)
        let databaseURL = databaseDirectory.appendingPathComponent(Self.defaultDatabaseFilename)

        return DashboardRepositoryConfiguration(databaseURL: databaseURL)
    }
}

public struct UnavailableDashboardRepository: DashboardRepository {
    private let error: DashboardRepositoryError

    public init(error: DashboardRepositoryError) {
        self.error = error
    }

    public func fetchDashboard(range: DashboardTimeRange) async throws -> DashboardSnapshot {
        throw error
    }
}

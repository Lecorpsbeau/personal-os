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
        self.staleAfter = staleAfter.isFinite ? max(0.1, staleAfter) : 10
        self.now = now
    }

    public static func local(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        workingDirectory: URL? = nil
    ) -> DashboardRepositoryConfiguration {
        let currentDirectory = workingDirectory
            ?? URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let statusPath = environment["MAC_DETECTIVE_RUNTIME_STATUS"]

        if let databasePath = environment["MAC_DETECTIVE_DATABASE"] {
            let databaseURL = fileURL(
                for: databasePath,
                relativeTo: currentDirectory
            )
            let statusURL = statusPath.map {
                fileURL(for: $0, relativeTo: currentDirectory)
            }
            return DashboardRepositoryConfiguration(
                databaseURL: databaseURL,
                runtimeStatusURL: statusURL
            )
        }

        if let rootPath = environment["PERSONAL_OS_ROOT"] {
            let rootURL = fileURL(for: rootPath, relativeTo: currentDirectory)
            let databaseURL = rootURL
                .appendingPathComponent("data/database", isDirectory: true)
                .appendingPathComponent(Self.defaultDatabaseFilename)
            return DashboardRepositoryConfiguration(
                databaseURL: databaseURL,
                runtimeStatusURL: statusPath.map {
                    fileURL(for: $0, relativeTo: currentDirectory)
                }
            )
        }

        var candidates: [URL] = [currentDirectory]

        // An explicit working directory is authoritative. This keeps local
        // configuration deterministic for embedders and tests; automatic
        // discovery is only used for the normal process launch.
        if workingDirectory == nil {
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
        }

        let databaseDirectory = candidates
            .map { $0.appendingPathComponent("data/database", isDirectory: true) }
            .first { fileManager.fileExists(atPath: $0.appendingPathComponent(Self.defaultDatabaseFilename).path) }
            ?? candidates[0].appendingPathComponent("data/database", isDirectory: true)
        let databaseURL = databaseDirectory.appendingPathComponent(Self.defaultDatabaseFilename)

        return DashboardRepositoryConfiguration(
            databaseURL: databaseURL,
            runtimeStatusURL: statusPath.map {
                fileURL(for: $0, relativeTo: currentDirectory)
            }
        )
    }

    private static func fileURL(for path: String, relativeTo directory: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
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

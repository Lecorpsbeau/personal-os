import Foundation

/// Keeps a read-only SQLite connection open between refreshes, while allowing
/// the dashboard to recover when the database is temporarily unavailable.
/// A failed attempt is closed and retried on the next refresh.
public actor RetryingSQLiteDashboardRepository: DashboardRepository {
    private let configuration: DashboardRepositoryConfiguration
    private var repository: SQLiteDashboardRepository?

    public init(configuration: DashboardRepositoryConfiguration) {
        self.configuration = configuration
    }

    public func fetchDashboard(
        range: DashboardTimeRange
    ) async throws -> DashboardSnapshot {
        do {
            if repository == nil {
                repository = try SQLiteDashboardRepository(
                    configuration: configuration
                )
            }
            guard let repository else {
                throw DashboardRepositoryError.sqlite(
                    message: "database repository is unavailable"
                )
            }
            return try await repository.fetchDashboard(range: range)
        } catch {
            repository?.close()
            repository = nil
            throw error
        }
    }

    public func close() {
        repository?.close()
        repository = nil
    }
}

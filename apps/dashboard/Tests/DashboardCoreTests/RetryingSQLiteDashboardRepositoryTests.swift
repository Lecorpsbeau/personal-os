import Foundation
import Testing
@testable import DashboardCore

@Suite("Retrying Dashboard Repository")
struct RetryingSQLiteDashboardRepositoryTests {
    @Test("A missing database can become readable on a later refresh")
    func testRecoversWhenDatabaseAppears() async throws {
        let source = try DashboardDatabaseFixture(includeRows: false)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("retry-dashboard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("mac_detective.sqlite")
        let repository = RetryingSQLiteDashboardRepository(
            configuration: DashboardRepositoryConfiguration(databaseURL: databaseURL)
        )

        await #expect(throws: DashboardRepositoryError.databaseMissing(path: databaseURL.path)) {
            try await repository.fetchDashboard(range: .oneHour)
        }

        try FileManager.default.copyItem(
            at: source.databaseURL,
            to: databaseURL
        )
        let snapshot = try await repository.fetchDashboard(range: .oneHour)
        #expect(snapshot.overview == .noData)
        await repository.close()
    }
}

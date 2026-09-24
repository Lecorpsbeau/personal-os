import Foundation
import SQLite3
import Testing
@testable import DashboardCore

@Suite("SQLite Dashboard Repository")
struct SQLiteDashboardRepositoryTests {
    @Test("Empty database returns explicit no-data state")
    func testEmptyDatabase() async throws {
        let fixture = try DashboardDatabaseFixture(includeRows: false)
        let repository = try SQLiteDashboardRepository(
            configuration: fixture.makeConfiguration()
        )
        defer { repository.close() }

        let snapshot = try await repository.fetchDashboard(range: .oneHour)

        #expect(snapshot.overview == .noData)
        #expect(snapshot.history.isEmpty)
        #expect(snapshot.rankings == ProcessRankings())
        #expect(snapshot.events.isEmpty)
        #expect(snapshot.runtime.isAvailable == false)
    }

    @Test("Recent samples expose current average and maximum values")
    func testRecentSamples() async throws {
        let fixture = try DashboardDatabaseFixture()
        let repository = try SQLiteDashboardRepository(
            configuration: fixture.makeConfiguration()
        )
        defer { repository.close() }

        let snapshot = try await repository.fetchDashboard(range: .oneHour)

        #expect(snapshot.overview.latestTimestamp == fixture.now)
        #expect(snapshot.overview.cpu.current == 50)
        #expect(snapshot.overview.cpu.average == 30)
        #expect(snapshot.overview.cpu.maximum == 50)
        #expect(snapshot.overview.memory.current == 60)
        #expect(snapshot.overview.diskRead.maximum == 5)
        #expect(snapshot.overview.diskWrite.maximum == 6)
        #expect(snapshot.overview.networkIn.maximum == 7)
        #expect(snapshot.overview.networkOut.maximum == 8)
        #expect(snapshot.overview.droppedEvents == 2)
        #expect(snapshot.history.count == 3)
    }

    @Test("One day history uses hourly aggregates")
    func testHistoricalAggregation() async throws {
        let fixture = try DashboardDatabaseFixture()
        let repository = try SQLiteDashboardRepository(
            configuration: fixture.makeConfiguration()
        )
        defer { repository.close() }

        let snapshot = try await repository.fetchDashboard(range: .oneDay)

        #expect(snapshot.history.count == 1)
        #expect(snapshot.history.first?.isAggregate == true)
        #expect(snapshot.overview.cpu.average == 20)
        #expect(snapshot.overview.cpu.maximum == 40)
        #expect(snapshot.overview.memory.average == 30)
    }

    @Test("Process rankings expose CPU RAM and disk values")
    func testProcessRankings() async throws {
        let fixture = try DashboardDatabaseFixture()
        let repository = try SQLiteDashboardRepository(
            configuration: fixture.makeConfiguration()
        )
        defer { repository.close() }

        let snapshot = try await repository.fetchDashboard(range: .oneHour)

        #expect(snapshot.rankings.cpu.first?.pid == 101)
        #expect(snapshot.rankings.memory.first?.pid == 102)
        #expect(snapshot.rankings.disk.first?.name == "beta")
        #expect(snapshot.rankings.disk.first?.diskTotalBytes == 2100)
        #expect(snapshot.rankings.disk.first?.diskReadBytesPerSecond != nil)
    }

    @Test("Events are newest first and limited")
    func testEventsOrderingAndLimit() async throws {
        let fixture = try DashboardDatabaseFixture()
        try fixture.insertAdditionalEvents(count: 60)
        let repository = try SQLiteDashboardRepository(
            configuration: fixture.makeConfiguration()
        )
        defer { repository.close() }

        let snapshot = try await repository.fetchDashboard(range: .oneHour)

        #expect(snapshot.events.count == 50)
        #expect(snapshot.events.first?.type == "TEST_EVENT")
        #expect(
            zip(snapshot.events, snapshot.events.dropFirst())
                .allSatisfy { $0.timestamp >= $1.timestamp }
        )
    }

    @Test("Missing database is reported without creating a file")
    func testMissingDatabase() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("missing-dashboard-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = directory.appendingPathComponent("missing.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try SQLiteDashboardRepository(
                configuration: DashboardRepositoryConfiguration(databaseURL: databaseURL)
            )
            Issue.record("Expected missing database error")
        } catch let error as DashboardRepositoryError {
            #expect(error == .databaseMissing(path: databaseURL.path))
            #expect(FileManager.default.fileExists(atPath: databaseURL.path) == false)
        }
    }

    @Test("Schema mismatch is rejected")
    func testSchemaMismatch() throws {
        let fixture = try DashboardDatabaseFixture(schemaVersion: 3, includeRows: false)
        do {
            _ = try SQLiteDashboardRepository(
                configuration: fixture.makeConfiguration()
            )
            Issue.record("Expected schema mismatch")
        } catch let error as DashboardRepositoryError {
            #expect(
                error == .schemaMismatch(
                    expected: DashboardRepositoryConfiguration.currentSchemaVersion,
                    actual: 3
                )
            )
        }
    }

    @Test("Invalid SQLite file reports a SQLite error")
    func testInvalidSQLiteFile() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("invalid-dashboard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("invalid.sqlite")
        try Data("not a sqlite database".utf8).write(to: databaseURL)

        do {
            _ = try SQLiteDashboardRepository(
                configuration: DashboardRepositoryConfiguration(databaseURL: databaseURL)
            )
            Issue.record("Expected SQLite error")
        } catch let error as DashboardRepositoryError {
            if case .sqlite = error {
                return
            }
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Repository never modifies the database file")
    func testReadOnlyConnection() async throws {
        let fixture = try DashboardDatabaseFixture()
        let before = try Data(contentsOf: fixture.databaseURL)
        let repository = try SQLiteDashboardRepository(
            configuration: fixture.makeConfiguration()
        )
        defer { repository.close() }

        _ = try await repository.fetchDashboard(range: .oneHour)
        let after = try Data(contentsOf: fixture.databaseURL)

        #expect(before == after)
    }

    @Test("WAL database is read without copying files")
    func testWALReadOnlyAccess() async throws {
        let fixture = try DashboardDatabaseFixture(useWAL: true)
        let repository = try SQLiteDashboardRepository(
            configuration: fixture.makeConfiguration()
        )
        defer { repository.close() }

        let snapshot = try await repository.fetchDashboard(range: .oneHour)
        #expect(snapshot.overview.cpu.current == 50)
        #expect(FileManager.default.fileExists(atPath: fixture.databaseURL.path))
    }

    @Test("Runtime status distinguishes current stale and unknown")
    func testRuntimeStatus() async throws {
        let fixture = try DashboardDatabaseFixture(includeRows: false)
        try fixture.writeRuntimeStatus()
        let repository = try SQLiteDashboardRepository(
            configuration: fixture.makeConfiguration()
        )
        defer { repository.close() }

        let current = try await repository.fetchDashboard(range: .oneHour)
        #expect(current.runtime.isAvailable)
        if case .current = current.runtime {
            // Expected branch is covered by the boolean assertion above.
        } else {
            Issue.record("Expected current runtime status")
        }

        try fixture.writeRuntimeStatus(
            updatedAt: fixture.now.addingTimeInterval(-60)
        )
        let stale = try await repository.fetchDashboard(range: .oneHour)
        if case .stale = stale.runtime {
            // Expected branch.
        } else {
            Issue.record("Expected stale runtime status")
        }

        try FileManager.default.removeItem(at: fixture.statusURL)
        let unknown = try await repository.fetchDashboard(range: .oneHour)
        #expect(unknown.runtime.isAvailable == false)
    }

    @Test("Important queries use the existing timestamp and snapshot indexes")
    func testQueryPlansUseIndexes() throws {
        let fixture = try DashboardDatabaseFixture()
        var connection: OpaquePointer?
        guard sqlite3_open(fixture.databaseURL.path, &connection) == SQLITE_OK else {
            Issue.record("Could not open fixture")
            return
        }
        defer { sqlite3_close_v2(connection) }

        let queries = [
            "EXPLAIN QUERY PLAN SELECT timestamp FROM system_samples WHERE timestamp >= 0 ORDER BY timestamp ASC;",
            "EXPLAIN QUERY PLAN SELECT pid, cpu FROM process_samples WHERE snapshot_id = 3 ORDER BY cpu DESC;",
            "EXPLAIN QUERY PLAN SELECT id FROM events ORDER BY timestamp DESC, id DESC LIMIT 50;",
            """
            EXPLAIN QUERY PLAN
            SELECT process_name, SUM(bytes)
            FROM disk_process_events
            WHERE snapshot_id = 3
            GROUP BY process_name;
            """
        ]
        var plans: [String] = []
        for query in queries {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(connection, query, -1, &statement, nil) == SQLITE_OK else {
                Issue.record("Could not prepare query plan")
                continue
            }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                if let pointer = sqlite3_column_text(statement, 3) {
                    plans.append(String(cString: pointer))
                }
            }
        }
        #expect(plans.contains { $0.contains("idx_system_samples_timestamp") })
        #expect(plans.contains { $0.contains("idx_process_samples_snapshot_cpu") })
        #expect(plans.contains { $0.contains("idx_disk_process_events_snapshot_id") })
    }
}

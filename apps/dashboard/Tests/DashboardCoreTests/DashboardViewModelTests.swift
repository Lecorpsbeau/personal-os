import Foundation
import Testing
@testable import DashboardCore

private actor MockDashboardRepository: DashboardRepository {
    enum Failure: Error {
        case unavailable
        case missing
        case schema
    }

    private let snapshot: DashboardSnapshot?
    private let failure: Failure?
    private let delayNanoseconds: UInt64?
    private(set) var callCount = 0
    private(set) var receivedRanges: [DashboardTimeRange] = []

    init(
        snapshot: DashboardSnapshot? = nil,
        failure: Failure? = nil,
        delayNanoseconds: UInt64? = nil
    ) {
        self.snapshot = snapshot
        self.failure = failure
        self.delayNanoseconds = delayNanoseconds
    }

    func fetchDashboard(range: DashboardTimeRange) async throws -> DashboardSnapshot {
        callCount += 1
        receivedRanges.append(range)
        if let delayNanoseconds {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        } else {
            await Task.yield()
        }
        if let failure {
            switch failure {
            case .missing:
                throw DashboardRepositoryError.databaseMissing(path: "/tmp/missing.sqlite")
            case .schema:
                throw DashboardRepositoryError.schemaMismatch(
                    expected: 4,
                    actual: 3
                )
            case .unavailable:
                throw failure
            }
        }
        guard let snapshot else {
            throw Failure.unavailable
        }
        return DashboardSnapshot(
            generatedAt: snapshot.generatedAt,
            range: range,
            overview: snapshot.overview,
            history: snapshot.history,
            rankings: snapshot.rankings,
            events: snapshot.events,
            runtime: snapshot.runtime,
            fsUsage: snapshot.fsUsage,
            databasePath: snapshot.databasePath,
            schemaVersion: snapshot.schemaVersion
        )
    }
}

@Suite("Dashboard ViewModel")
@MainActor
struct DashboardViewModelTests {
    @Test("Refresh loads data and clears previous error")
    func testRefreshSuccess() async {
        let snapshot = makeSnapshot()
        let repository = MockDashboardRepository(snapshot: snapshot)
        let viewModel = DashboardViewModel(repository: repository)

        await viewModel.refresh()

        #expect(viewModel.snapshot == snapshot)
        #expect(viewModel.lastError == nil)
        #expect(viewModel.isRefreshing == false)
    }

    @Test("Refresh errors retain stale data and expose error")
    func testRefreshErrorRetainsStaleData() async {
        let firstSnapshot = makeSnapshot()
        let repository = MutableFailureRepository(initial: .success(firstSnapshot))
        let viewModel = DashboardViewModel(repository: repository)

        await viewModel.refresh()
        await repository.setFailure(.failure)
        await viewModel.refresh()

        #expect(viewModel.snapshot == firstSnapshot)
        #expect(viewModel.lastError != nil)
        #expect(viewModel.isRefreshing == false)
    }

    @Test("Concurrent refreshes do not overlap")
    func testRefreshDoesNotOverlap() async {
        let repository = MockDashboardRepository(snapshot: makeSnapshot())
        let viewModel = DashboardViewModel(repository: repository)

        async let first: Void = viewModel.refresh()
        async let second: Void = viewModel.refresh()
        _ = await (first, second)

        #expect(await repository.callCount == 1)
    }

    @Test("UX state maps missing and incompatible databases")
    func testDatabaseFailureUXStates() async {
        let missingRepository = MockDashboardRepository(failure: .missing)
        let missingViewModel = DashboardViewModel(repository: missingRepository)
        await missingViewModel.refresh()
        #expect(missingViewModel.state == .databaseMissing)

        let schemaRepository = MockDashboardRepository(failure: .schema)
        let schemaViewModel = DashboardViewModel(repository: schemaRepository)
        await schemaViewModel.refresh()
        #expect(schemaViewModel.state == .schemaMismatch)
    }

    @Test("UX state exposes no-data and runtime-unavailable states")
    func testUXStates() async {
        let noDataRepository = MockDashboardRepository(snapshot: makeSnapshot())
        let noDataViewModel = DashboardViewModel(repository: noDataRepository)
        await noDataViewModel.refresh()
        #expect(noDataViewModel.state == .noData)

        let dataSnapshot = makeSnapshot(
            overview: DashboardOverview(
                latestTimestamp: Date(timeIntervalSince1970: 1_900_000_000),
                cpu: MetricSummary(current: 12),
                memory: .noData,
                diskRead: .noData,
                diskWrite: .noData,
                networkIn: .noData,
                networkOut: .noData,
                droppedEvents: nil
            )
        )
        let runtimeRepository = MockDashboardRepository(snapshot: dataSnapshot)
        let runtimeViewModel = DashboardViewModel(repository: runtimeRepository)
        await runtimeViewModel.refresh()
        #expect(runtimeViewModel.state == .runtimeUnavailable)
    }

    @Test("UX state exposes a stopped runtime separately from stale data")
    func testStoppedRuntimeState() async {
        let timestamp = Date(timeIntervalSince1970: 1_900_000_000)
        let snapshot = makeSnapshot(
            overview: DashboardOverview(
                latestTimestamp: timestamp,
                cpu: MetricSummary(current: 12),
                memory: .noData,
                diskRead: .noData,
                diskWrite: .noData,
                networkIn: .noData,
                networkOut: .noData,
                droppedEvents: nil
            ),
            runtime: .current(
                RuntimeStatusPayload(
                    version: 1,
                    state: "stopped",
                    updatedAt: timestamp,
                    cyclesExecuted: 1,
                    lastCycleAt: timestamp,
                    lastSuccessfulPersistenceAt: timestamp,
                    lastMaintenanceAt: nil,
                    fsUsage: nil
                )
            )
        )
        let viewModel = DashboardViewModel(
            repository: MockDashboardRepository(snapshot: snapshot)
        )

        await viewModel.refresh()

        #expect(viewModel.state == .runtimeStopped)
        #expect(viewModel.freshness == .runtimeStopped)
    }

    @Test("A range change queues a fresh result instead of publishing the old range")
    func testRangeChangeWhileRefreshing() async throws {
        let repository = MockDashboardRepository(
            snapshot: makeSnapshot(),
            delayNanoseconds: 100_000_000
        )
        let viewModel = DashboardViewModel(repository: repository)

        let firstRefresh = Task { @MainActor in
            await viewModel.refresh()
        }
        for _ in 0..<100 {
            if await repository.callCount > 0 {
                break
            }
            await Task.yield()
        }
        #expect(await repository.callCount == 1)
        viewModel.selectedRange = .oneDay
        let secondRefresh = Task { @MainActor in
            await viewModel.refresh()
        }
        await firstRefresh.value
        await secondRefresh.value

        #expect(await repository.receivedRanges == [.oneHour, .oneDay])
        #expect(viewModel.snapshot?.range == .oneDay)
    }

    @Test("Selected range is passed to repository")
    func testSelectedRange() async {
        let repository = MockDashboardRepository(snapshot: makeSnapshot())
        let viewModel = DashboardViewModel(
            repository: repository,
            selectedRange: .oneDay
        )

        await viewModel.refresh()

        #expect(await repository.receivedRanges == [.oneDay])
    }

    private func makeSnapshot(
        overview: DashboardOverview = .noData,
        runtime: RuntimeObservation = .unknown(reason: "test")
    ) -> DashboardSnapshot {
        DashboardSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_900_000_000),
            range: .oneHour,
            overview: overview,
            history: [],
            rankings: ProcessRankings(),
            events: [],
            runtime: runtime,
            fsUsage: nil
        )
    }
}

private actor MutableFailureRepository: DashboardRepository {
    enum ResultState {
        case success(DashboardSnapshot)
        case failure
    }

    private var state: ResultState
    private(set) var callCount = 0

    init(initial: ResultState) {
        state = initial
    }

    func setFailure(_ state: ResultState) {
        self.state = state
    }

    func fetchDashboard(range: DashboardTimeRange) async throws -> DashboardSnapshot {
        callCount += 1
        switch state {
        case .success(let snapshot):
            return snapshot
        case .failure:
            throw MockDashboardRepository.Failure.unavailable
        }
    }
}

import Foundation
import Testing
@testable import DashboardCore

private actor MockDashboardRepository: DashboardRepository {
    enum Failure: Error {
        case unavailable
    }

    private let snapshot: DashboardSnapshot?
    private let failure: Failure?
    private(set) var callCount = 0
    private(set) var receivedRanges: [DashboardTimeRange] = []

    init(
        snapshot: DashboardSnapshot? = nil,
        failure: Failure? = nil
    ) {
        self.snapshot = snapshot
        self.failure = failure
    }

    func fetchDashboard(range: DashboardTimeRange) async throws -> DashboardSnapshot {
        callCount += 1
        receivedRanges.append(range)
        await Task.yield()
        if let failure {
            throw failure
        }
        guard let snapshot else {
            throw Failure.unavailable
        }
        return snapshot
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

    private func makeSnapshot() -> DashboardSnapshot {
        DashboardSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_900_000_000),
            range: .oneHour,
            overview: DashboardOverview.noData,
            history: [],
            rankings: ProcessRankings(),
            events: [],
            runtime: .unknown(reason: "test"),
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

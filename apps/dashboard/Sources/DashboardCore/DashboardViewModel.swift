import Combine
import Foundation

@MainActor
public final class DashboardViewModel: ObservableObject {
    @Published public private(set) var snapshot: DashboardSnapshot?
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var freshness: DashboardFreshness = .runtimeUnknown
    @Published public private(set) var state: DashboardUXState = .idle
    @Published public private(set) var databasePath: String
    @Published public private(set) var schemaVersion: Int?
    @Published public var selectedRange: DashboardTimeRange

    private let repository: any DashboardRepository
    private let freshnessPolicy: DashboardFreshnessPolicy
    private let refreshInterval: TimeInterval
    private var refreshTask: Task<Void, Never>?
    private var refreshInFlight = false
    private var refreshRequestedWhileInFlight = false
    private var inFlightRange: DashboardTimeRange?

    public init(
        repository: any DashboardRepository,
        selectedRange: DashboardTimeRange = .oneHour,
        refreshInterval: TimeInterval = 2,
        freshnessPolicy: DashboardFreshnessPolicy = DashboardFreshnessPolicy(),
        databasePath: String = "",
        schemaVersion: Int? = nil
    ) {
        self.repository = repository
        self.selectedRange = selectedRange
        self.refreshInterval = refreshInterval.isFinite
            ? min(max(0.25, refreshInterval), 3_600)
            : 2
        self.freshnessPolicy = freshnessPolicy
        self.databasePath = databasePath
        self.schemaVersion = schemaVersion
    }

    deinit {
        refreshTask?.cancel()
    }

    public func refresh() async {
        if refreshInFlight {
            if inFlightRange != selectedRange {
                refreshRequestedWhileInFlight = true
            }
            return
        }

        refreshInFlight = true
        inFlightRange = selectedRange
        isRefreshing = true
        if snapshot == nil {
            state = .loading
        }
        defer {
            isRefreshing = false
            refreshInFlight = false
            inFlightRange = nil
        }

        repeat {
            refreshRequestedWhileInFlight = false
            await performRefresh()
        } while refreshRequestedWhileInFlight && !Task.isCancelled
    }

    private func performRefresh() async {
        let range = selectedRange

        do {
            let freshSnapshot = try await repository.fetchDashboard(range: range)
            guard !Task.isCancelled else {
                return
            }
            // A range can change while an older request is in flight. Do not
            // publish that older result; the pending pass will fetch the new
            // range before the refresh cycle ends.
            guard selectedRange == range, freshSnapshot.range == range else {
                refreshRequestedWhileInFlight = true
                return
            }
            snapshot = freshSnapshot
            if !freshSnapshot.databasePath.isEmpty {
                databasePath = freshSnapshot.databasePath
            }
            if let schemaVersion = freshSnapshot.schemaVersion {
                self.schemaVersion = schemaVersion
            }
            freshness = freshnessPolicy.evaluate(freshSnapshot)
            state = uxState(for: freshSnapshot)
            lastError = nil
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else {
                return
            }
            guard selectedRange == range else {
                refreshRequestedWhileInFlight = true
                return
            }
            if snapshot != nil {
                freshness = .stale
                state = .stale(message: error.localizedDescription)
            } else {
                state = uxState(for: error)
            }
            lastError = error.localizedDescription
        }
    }

    private func uxState(for snapshot: DashboardSnapshot) -> DashboardUXState {
        switch snapshot.runtime {
        case .unknown:
            if snapshot.overview == .noData, snapshot.history.isEmpty {
                return .noData
            }
            return .runtimeUnavailable
        case .stale(let payload):
            switch payload.state.lowercased() {
            case "stopped":
                return .runtimeStopped
            case "failed":
                return .runtimeFailed
            default:
                return .stale(message: "Runtime status is stale")
            }
        case .current(let payload):
            switch payload.state.lowercased() {
            case "stopped":
                return .runtimeStopped
            case "failed":
                return .runtimeFailed
            case "stopping":
                return .runtimeStopping
            default:
                if snapshot.overview == .noData, snapshot.history.isEmpty {
                    return .noData
                }
                return .ready
            }
        }
    }

    private func uxState(for error: Error) -> DashboardUXState {
        guard let repositoryError = error as? DashboardRepositoryError else {
            return .failed(message: error.localizedDescription)
        }
        switch repositoryError {
        case .databaseMissing:
            return .databaseMissing
        case .schemaMismatch:
            return .schemaMismatch
        case .sqlite, .invalidData:
            return .failed(message: repositoryError.localizedDescription)
        }
    }

    public func startAutoRefresh() {
        guard refreshTask == nil else {
            return
        }

        let interval = refreshInterval
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(interval * 1_000_000_000)
                    )
                } catch {
                    break
                }
            }
        }
    }

    public func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }
}

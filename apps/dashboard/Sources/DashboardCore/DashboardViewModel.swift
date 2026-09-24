import Combine
import Foundation

@MainActor
public final class DashboardViewModel: ObservableObject {
    @Published public private(set) var snapshot: DashboardSnapshot?
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var lastError: String?
    @Published public var selectedRange: DashboardTimeRange

    private let repository: any DashboardRepository
    private let refreshInterval: TimeInterval
    private var refreshTask: Task<Void, Never>?
    private var refreshInFlight = false

    public init(
        repository: any DashboardRepository,
        selectedRange: DashboardTimeRange = .oneHour,
        refreshInterval: TimeInterval = 2
    ) {
        self.repository = repository
        self.selectedRange = selectedRange
        self.refreshInterval = max(0.25, refreshInterval)
    }

    deinit {
        refreshTask?.cancel()
    }

    public func refresh() async {
        guard !refreshInFlight else {
            return
        }

        refreshInFlight = true
        isRefreshing = true
        defer {
            isRefreshing = false
            refreshInFlight = false
        }
        let range = selectedRange

        do {
            let freshSnapshot = try await repository.fetchDashboard(range: range)
            guard !Task.isCancelled else {
                return
            }
            snapshot = freshSnapshot
            lastError = nil
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else {
                return
            }
            lastError = error.localizedDescription
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

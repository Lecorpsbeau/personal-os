import Foundation

public enum DashboardFreshness: Equatable, Sendable {
    case live
    case updated(secondsAgo: Int)
    case stale
    case noData
    case runtimeStopped
    case runtimeFailed
    case runtimeStopping
    case runtimeUnknown

    public var title: String {
        switch self {
        case .live:
            return "Live"
        case .updated(let seconds):
            return "Updated \(seconds)s ago"
        case .stale:
            return "Stale"
        case .noData:
            return "No data"
        case .runtimeStopped:
            return "Runtime stopped"
        case .runtimeFailed:
            return "Runtime failed"
        case .runtimeStopping:
            return "Runtime stopping"
        case .runtimeUnknown:
            return "Runtime unknown"
        }
    }
}

public struct DashboardFreshnessPolicy: Sendable {
    public let staleAfter: TimeInterval
    public let liveWindow: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        staleAfter: TimeInterval = 10,
        liveWindow: TimeInterval = 2,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.staleAfter = staleAfter.isFinite ? max(0.1, staleAfter) : 10
        self.liveWindow = liveWindow.isFinite ? max(0, liveWindow) : 2
        self.now = now
    }

    public func evaluate(_ snapshot: DashboardSnapshot) -> DashboardFreshness {
        switch snapshot.runtime {
        case .unknown:
            return .runtimeUnknown
        case .stale(let payload):
            switch payload.state.lowercased() {
            case "stopped":
                return .runtimeStopped
            case "failed":
                return .runtimeFailed
            default:
                return .stale
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
                guard let latest = snapshot.overview.latestTimestamp else {
                    return .noData
                }
                let age = max(0, now().timeIntervalSince(latest))
                if age > staleAfter {
                    return .stale
                }
                if age <= liveWindow {
                    return .live
                }
                return .updated(secondsAgo: max(1, Int(age.rounded(.down))))
            }
        }
    }
}

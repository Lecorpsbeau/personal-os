import Foundation

public enum DashboardUXState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case noData
    case stale(message: String)
    case databaseMissing
    case schemaMismatch
    case runtimeUnavailable
    case runtimeStopped
    case runtimeFailed
    case runtimeStopping
    case failed(message: String)

    public var title: String {
        switch self {
        case .idle:
            return "Idle"
        case .loading:
            return "Loading"
        case .ready:
            return "Ready"
        case .noData:
            return "No data"
        case .stale:
            return "Stale"
        case .databaseMissing:
            return "Database missing"
        case .schemaMismatch:
            return "Schema incompatible"
        case .runtimeUnavailable:
            return "Runtime unavailable"
        case .runtimeStopped:
            return "Runtime stopped"
        case .runtimeFailed:
            return "Runtime failed"
        case .runtimeStopping:
            return "Runtime stopping"
        case .failed:
            return "Error"
        }
    }
}

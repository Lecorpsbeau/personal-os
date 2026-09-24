import Foundation

enum RuntimeConfigurationError: Error, Equatable {
    case invalidSamplingInterval
    case invalidMaintenanceInterval
}

struct RuntimeConfiguration: Equatable, Sendable {
    let samplingInterval: TimeInterval
    let maintenanceInterval: TimeInterval
    let logLevel: RuntimeLogLevel
    let fsUsageEnabled: Bool

    init(
        samplingInterval: TimeInterval = 2,
        maintenanceInterval: TimeInterval = 3_600,
        logLevel: RuntimeLogLevel = .info,
        fsUsageEnabled: Bool = true
    ) throws {
        try Self.validate(
            samplingInterval: samplingInterval,
            maintenanceInterval: maintenanceInterval
        )

        self.samplingInterval = samplingInterval
        self.maintenanceInterval = maintenanceInterval
        self.logLevel = logLevel
        self.fsUsageEnabled = fsUsageEnabled
    }

    // Keep the programmatic/test default compatible; the executable entry
    // point selects fs_usage from its explicit environment opt-in.
    static let standard = try! RuntimeConfiguration()

    static func validate(
        samplingInterval: TimeInterval,
        maintenanceInterval: TimeInterval
    ) throws {
        guard samplingInterval.isFinite, samplingInterval > 0 else {
            throw RuntimeConfigurationError.invalidSamplingInterval
        }
        guard maintenanceInterval.isFinite, maintenanceInterval > 0 else {
            throw RuntimeConfigurationError.invalidMaintenanceInterval
        }
    }
}

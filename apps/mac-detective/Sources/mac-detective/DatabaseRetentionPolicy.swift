import Foundation

struct DatabaseRetentionPolicy: Equatable, Sendable {
    let detailedRetentionDays: Int
    let hourlyRetentionDays: Int
    let dailyRetentionDays: Int
    let maintenanceInterval: TimeInterval

    init(
        detailedRetentionDays: Int,
        hourlyRetentionDays: Int,
        dailyRetentionDays: Int,
        maintenanceInterval: TimeInterval = 3_600
    ) {
        precondition(detailedRetentionDays >= 0)
        precondition(hourlyRetentionDays >= 0)
        precondition(dailyRetentionDays >= 0)
        precondition(maintenanceInterval > 0)

        self.detailedRetentionDays = detailedRetentionDays
        self.hourlyRetentionDays = hourlyRetentionDays
        self.dailyRetentionDays = dailyRetentionDays
        self.maintenanceInterval = maintenanceInterval
    }

    // Defaults live outside Database.swift so deployments can choose a
    // different policy without changing persistence code.
    static let standard = DatabaseRetentionPolicy(
        detailedRetentionDays: 7,
        hourlyRetentionDays: 30,
        dailyRetentionDays: 365
    )

    func cutoff(afterDays days: Int, now: Date) -> Date {
        now.addingTimeInterval(-Double(days) * 86_400)
    }
}

struct DatabaseMaintenanceReport: Equatable, Sendable {
    let deletedSystemSamples: Int
    let deletedProcessSamples: Int
    let deletedDiskProcessEvents: Int
    let deletedEvents: Int
    let deletedHourlySystemStats: Int
    let deletedHourlyProcessStats: Int
    let deletedDailySystemStats: Int
    let deletedDailyProcessStats: Int
    let refreshedHourlySystemStats: Int
    let refreshedHourlyProcessStats: Int
    let refreshedDailySystemStats: Int
    let refreshedDailyProcessStats: Int
    let processedDirtyBuckets: Int
    let remainingDirtyBuckets: Int

    init(
        deletedSystemSamples: Int,
        deletedProcessSamples: Int,
        deletedDiskProcessEvents: Int,
        deletedEvents: Int,
        deletedHourlySystemStats: Int,
        deletedHourlyProcessStats: Int,
        deletedDailySystemStats: Int,
        deletedDailyProcessStats: Int,
        refreshedHourlySystemStats: Int,
        refreshedHourlyProcessStats: Int,
        refreshedDailySystemStats: Int,
        refreshedDailyProcessStats: Int,
        processedDirtyBuckets: Int = 0,
        remainingDirtyBuckets: Int = 0
    ) {
        self.deletedSystemSamples = deletedSystemSamples
        self.deletedProcessSamples = deletedProcessSamples
        self.deletedDiskProcessEvents = deletedDiskProcessEvents
        self.deletedEvents = deletedEvents
        self.deletedHourlySystemStats = deletedHourlySystemStats
        self.deletedHourlyProcessStats = deletedHourlyProcessStats
        self.deletedDailySystemStats = deletedDailySystemStats
        self.deletedDailyProcessStats = deletedDailyProcessStats
        self.refreshedHourlySystemStats = refreshedHourlySystemStats
        self.refreshedHourlyProcessStats = refreshedHourlyProcessStats
        self.refreshedDailySystemStats = refreshedDailySystemStats
        self.refreshedDailyProcessStats = refreshedDailyProcessStats
        self.processedDirtyBuckets = processedDirtyBuckets
        self.remainingDirtyBuckets = remainingDirtyBuckets
    }

    var totalDeleted: Int {
        deletedSystemSamples +
        deletedProcessSamples +
        deletedDiskProcessEvents +
        deletedEvents +
        deletedHourlySystemStats +
        deletedHourlyProcessStats +
        deletedDailySystemStats +
        deletedDailyProcessStats
    }
}

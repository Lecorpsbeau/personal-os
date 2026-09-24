import Foundation

struct DatabaseRetentionPolicy: Equatable, Sendable {
    let detailedRetentionDays: Int
    let hourlyRetentionDays: Int
    let dailyRetentionDays: Int

    init(
        detailedRetentionDays: Int,
        hourlyRetentionDays: Int,
        dailyRetentionDays: Int
    ) {
        precondition(detailedRetentionDays >= 0)
        precondition(hourlyRetentionDays >= 0)
        precondition(dailyRetentionDays >= 0)

        self.detailedRetentionDays = detailedRetentionDays
        self.hourlyRetentionDays = hourlyRetentionDays
        self.dailyRetentionDays = dailyRetentionDays
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

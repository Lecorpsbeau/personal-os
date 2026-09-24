import Foundation

struct DetectorConfiguration: Equatable, Sendable {

    let cpuThreshold: Double
    let memoryThreshold: Double
    let diskReadThreshold: Double
    let diskWriteThreshold: Double
    let networkThreshold: Double

    let processDiskReadThreshold: Double
    let processDiskWriteThreshold: Double

    let cpuClearThreshold: Double
    let memoryClearThreshold: Double
    let diskReadClearThreshold: Double
    let diskWriteClearThreshold: Double
    let networkClearThreshold: Double
    let processDiskReadClearThreshold: Double
    let processDiskWriteClearThreshold: Double

    let cooldown: TimeInterval

    init(
        cpuThreshold: Double = 80,
        memoryThreshold: Double = 90,
        diskReadThreshold: Double = 100_000_000,
        diskWriteThreshold: Double = 100_000_000,
        networkThreshold: Double = 50_000_000,
        processDiskReadThreshold: Double? = nil,
        processDiskWriteThreshold: Double? = nil,
        cpuClearThreshold: Double = 70,
        memoryClearThreshold: Double = 80,
        diskReadClearThreshold: Double = 70_000_000,
        diskWriteClearThreshold: Double = 70_000_000,
        networkClearThreshold: Double = 35_000_000,
        processDiskReadClearThreshold: Double? = nil,
        processDiskWriteClearThreshold: Double? = nil,
        cooldown: TimeInterval = 60
    ) {
        precondition(cpuThreshold >= 0)
        precondition(memoryThreshold >= 0)
        precondition(diskReadThreshold >= 0)
        precondition(diskWriteThreshold >= 0)
        precondition(networkThreshold >= 0)
        precondition(cpuClearThreshold >= 0 && cpuClearThreshold <= cpuThreshold)
        precondition(memoryClearThreshold >= 0 && memoryClearThreshold <= memoryThreshold)
        precondition(diskReadClearThreshold >= 0 && diskReadClearThreshold <= diskReadThreshold)
        precondition(diskWriteClearThreshold >= 0 && diskWriteClearThreshold <= diskWriteThreshold)
        precondition(networkClearThreshold >= 0 && networkClearThreshold <= networkThreshold)
        precondition(cooldown >= 0)

        let resolvedProcessReadThreshold =
            processDiskReadThreshold ?? diskReadThreshold
        let resolvedProcessWriteThreshold =
            processDiskWriteThreshold ?? diskWriteThreshold
        let resolvedProcessReadClearThreshold =
            processDiskReadClearThreshold ??
            min(diskReadClearThreshold, resolvedProcessReadThreshold * 0.7)
        let resolvedProcessWriteClearThreshold =
            processDiskWriteClearThreshold ??
            min(diskWriteClearThreshold, resolvedProcessWriteThreshold * 0.7)

        precondition(resolvedProcessReadThreshold >= 0)
        precondition(resolvedProcessWriteThreshold >= 0)
        precondition(
            resolvedProcessReadClearThreshold >= 0 &&
                resolvedProcessReadClearThreshold <= resolvedProcessReadThreshold
        )
        precondition(
            resolvedProcessWriteClearThreshold >= 0 &&
                resolvedProcessWriteClearThreshold <= resolvedProcessWriteThreshold
        )

        self.cpuThreshold = cpuThreshold
        self.memoryThreshold = memoryThreshold
        self.diskReadThreshold = diskReadThreshold
        self.diskWriteThreshold = diskWriteThreshold
        self.networkThreshold = networkThreshold
        self.processDiskReadThreshold = resolvedProcessReadThreshold
        self.processDiskWriteThreshold = resolvedProcessWriteThreshold
        self.cpuClearThreshold = cpuClearThreshold
        self.memoryClearThreshold = memoryClearThreshold
        self.diskReadClearThreshold = diskReadClearThreshold
        self.diskWriteClearThreshold = diskWriteClearThreshold
        self.networkClearThreshold = networkClearThreshold
        self.processDiskReadClearThreshold = resolvedProcessReadClearThreshold
        self.processDiskWriteClearThreshold = resolvedProcessWriteClearThreshold
        self.cooldown = cooldown
    }

    static let standard = DetectorConfiguration()
}

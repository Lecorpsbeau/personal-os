import Foundation

struct SystemSnapshot {

    let timestamp: Date

    let cpu: Double
    let memory: Double

    let diskRead: Double
    let diskWrite: Double

    let networkIn: Double
    let networkOut: Double

    let processes: [ProcessSnapshot]

    // This is the number of fs_usage events dropped since the previous
    // persisted snapshot, not the collector's lifetime counter.
    let droppedEvents: Int

    init(
        timestamp: Date,
        cpu: Double,
        memory: Double,
        diskRead: Double,
        diskWrite: Double,
        networkIn: Double,
        networkOut: Double,
        processes: [ProcessSnapshot],
        droppedEvents: Int = 0
    ) {
        self.timestamp = timestamp
        self.cpu = cpu
        self.memory = memory
        self.diskRead = diskRead
        self.diskWrite = diskWrite
        self.networkIn = networkIn
        self.networkOut = networkOut
        self.processes = processes
        self.droppedEvents = max(0, droppedEvents)
    }
}

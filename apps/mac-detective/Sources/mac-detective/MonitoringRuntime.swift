import Foundation

enum RuntimeState: Equatable, Sendable {
    case stopped
    case running
    case stopping
    case failed(String)
}

enum RuntimeError: Error, Equatable, CustomStringConvertible {
    case collection(String)
    case fsUsage(String)
    case detection(String)
    case persistence(String)
    case maintenance(String)
    case checkpoint(String)
    case fatal(String)

    var category: String {
        switch self {
        case .collection:
            return "collection"
        case .fsUsage:
            return "fs_usage"
        case .detection:
            return "detection"
        case .persistence:
            return "persistence"
        case .maintenance:
            return "maintenance"
        case .checkpoint:
            return "checkpoint"
        case .fatal:
            return "fatal"
        }
    }

    var isFatal: Bool {
        if case .fatal = self {
            return true
        }
        return false
    }

    var description: String {
        switch self {
        case .collection(let message),
             .fsUsage(let message),
             .detection(let message),
             .persistence(let message),
             .maintenance(let message),
             .checkpoint(let message),
             .fatal(let message):
            return "\(category): \(message)"
        }
    }
}

struct RuntimeCycleMetrics: Equatable, Sendable {
    var cyclesExecuted: Int = 0
    var lastCycleAt: Date?
    var lastCycleDuration: TimeInterval?
    var recoverableErrors: Int = 0
    var fatalErrors: Int = 0
    var lastSuccessfulPersistenceAt: Date?
    var lastMaintenanceAt: Date?
}

protocol RuntimeClock: AnyObject {
    var now: Date { get }
}

final class SystemRuntimeClock: RuntimeClock {
    var now: Date {
        Date()
    }
}

protocol RuntimeWaiter: AnyObject {
    func wait(for interval: TimeInterval)
    func wake()
}

final class InterruptibleRuntimeWaiter: RuntimeWaiter, @unchecked Sendable {
    private let condition = NSCondition()
    private var wakePending = false

    func wait(for interval: TimeInterval) {
        let deadline = Date().addingTimeInterval(interval)
        condition.lock()
        if wakePending {
            wakePending = false
            condition.unlock()
            return
        }
        while !wakePending && condition.wait(until: deadline) {}
        if wakePending {
            wakePending = false
        }
        condition.unlock()
    }

    func wake() {
        condition.lock()
        wakePending = true
        condition.broadcast()
        condition.unlock()
    }
}

protocol RuntimeSnapshotCollector: AnyObject {
    var waitsBeforeFirstCycle: Bool { get }

    func start() throws
    func collect(droppedEvents: Int) throws -> SystemSnapshot
    func stop()
}

extension RuntimeSnapshotCollector {
    var waitsBeforeFirstCycle: Bool { false }
}

protocol RuntimeFSUsageSource: AnyObject {
    var droppedEventCount: Int { get }
    var diagnostic: String? { get }
    var stateName: String? { get }

    func start() throws
    func stop()
    func getBufferedEvents() throws -> [DiskProcessEvent]
    func acknowledgeBufferedEvents(count: Int)
    func acknowledgeBufferedEvents(_ events: [DiskProcessEvent]) -> Bool
}

extension RuntimeFSUsageSource {
    var diagnostic: String? { nil }
    var stateName: String? { nil }

    func acknowledgeBufferedEvents(_ events: [DiskProcessEvent]) -> Bool {
        acknowledgeBufferedEvents(count: events.count)
        return true
    }
}

protocol RuntimeDetectionEngine: AnyObject {
    func detect(snapshot: SystemSnapshot) throws -> [DetectedEvent]
}

protocol RuntimePersistence: AnyObject {
    func start() throws
    func save(
        snapshot: SystemSnapshot,
        diskProcessEvents: [DiskProcessEvent]
    ) throws -> Int64
    func save(
        event: DetectedEvent,
        snapshotID: Int64,
        timestamp: Date
    ) throws
    func savePendingDiskProcessEvents(
        _ events: [DiskProcessEvent],
        snapshotID: Int64?
    ) throws
    func performMaintenance(now: Date) throws -> DatabaseMaintenanceReport
    func checkpoint() throws -> Bool
    func close()
}

final class LiveSnapshotCollector: RuntimeSnapshotCollector {
    private let diskCollector: DiskCollector
    private let networkCollector: NetworkCollector
    private let processCollector: ProcessCollector

    init(
        diskCollector: DiskCollector = DiskCollector(),
        networkCollector: NetworkCollector = NetworkCollector(),
        processCollector: ProcessCollector = ProcessCollector()
    ) {
        self.diskCollector = diskCollector
        self.networkCollector = networkCollector
        self.processCollector = processCollector
    }

    func start() throws {
        _ = getCPUUsage()
        _ = diskCollector.sample()
        _ = networkCollector.sample()
        _ = processCollector.sample()
    }

    func collect(droppedEvents: Int) throws -> SystemSnapshot {
        let cpu = getCPUUsage()
        let memory = getMemoryUsage()
        let disk = diskCollector.sample()
        let network = networkCollector.sample()
        let processes = processCollector.sample()

        return SystemSnapshot(
            timestamp: Date(),
            cpu: cpu,
            memory: memory,
            diskRead: disk.readBytesPerSecond,
            diskWrite: disk.writeBytesPerSecond,
            networkIn: network.bytesInPerSecond,
            networkOut: network.bytesOutPerSecond,
            processes: processes,
            droppedEvents: droppedEvents
        )
    }

    var waitsBeforeFirstCycle: Bool { true }

    func stop() {}
}

final class FSUsageRuntimeSource: RuntimeFSUsageSource {
    private let collector: FSUsageCollector

    init(collector: FSUsageCollector) {
        self.collector = collector
    }

    var droppedEventCount: Int {
        collector.droppedEventCount
    }

    var diagnostic: String? {
        let status = collector.status
        if status.permissionDenied {
            let detail = status.stderrMessage.isEmpty
                ? "permission denied"
                : status.stderrMessage
            return "permission denied: \(detail)"
        }
        switch status.processState {
        case .launchFailed(let message):
            return "launch failed: \(message)"
        case .terminated(let exitCode):
            return "terminated with exit code \(exitCode)"
        case .outputPipeClosed:
            return "output pipe closed"
        case .starting, .running, .stopped:
            return nil
        }
    }

    var stateName: String? {
        switch collector.status.processState {
        case .starting:
            return "starting"
        case .running:
            return "running"
        case .launchFailed:
            return "launchFailed"
        case .terminated:
            return "terminated"
        case .outputPipeClosed:
            return "outputPipeClosed"
        case .stopped:
            return "stopped"
        }
    }

    func start() throws {
        collector.start()
    }

    func stop() {
        collector.stopAndDrain()
    }

    func getBufferedEvents() throws -> [DiskProcessEvent] {
        collector.getBufferedEvents()
    }

    func acknowledgeBufferedEvents(count: Int) {
        collector.acknowledgeBufferedEvents(count: count)
    }

    func acknowledgeBufferedEvents(_ events: [DiskProcessEvent]) -> Bool {
        collector.acknowledgeBufferedEvents(events)
    }
}

final class DisabledFSUsageRuntimeSource: RuntimeFSUsageSource {
    var droppedEventCount: Int { 0 }
    var diagnostic: String? { "disabled (opt-in with MAC_DETECTIVE_FS_USAGE=1)" }
    var stateName: String? { "disabled" }

    func start() throws {}
    func stop() {}
    func getBufferedEvents() throws -> [DiskProcessEvent] { [] }
    func acknowledgeBufferedEvents(count: Int) {}
    func acknowledgeBufferedEvents(_ events: [DiskProcessEvent]) -> Bool { true }
}

final class DetectorRuntimeAdapter: RuntimeDetectionEngine {
    let detector: Detector

    init(detector: Detector) {
        self.detector = detector
    }

    func detect(snapshot: SystemSnapshot) throws -> [DetectedEvent] {
        detector.detect(snapshot: snapshot)
    }
}

final class DatabaseRuntimePersistence: RuntimePersistence {
    private let database: Database

    init(database: Database) {
        self.database = database
    }

    func start() throws {
        guard database.isReady else {
            throw RuntimeError.persistence("database is not ready")
        }
    }

    func save(
        snapshot: SystemSnapshot,
        diskProcessEvents: [DiskProcessEvent]
    ) throws -> Int64 {
        guard let snapshotID = database.save(
            snapshot: snapshot,
            diskProcessEvents: diskProcessEvents
        ) else {
            throw RuntimeError.persistence("snapshot was not persisted")
        }
        return snapshotID
    }

    func save(
        event: DetectedEvent,
        snapshotID: Int64,
        timestamp: Date
    ) throws {
        try database.saveEventThrowing(
            event,
            snapshotID: snapshotID,
            timestamp: timestamp
        )
    }

    func savePendingDiskProcessEvents(
        _ events: [DiskProcessEvent],
        snapshotID: Int64?
    ) throws {
        guard !events.isEmpty else {
            return
        }
        let savedCount = database.saveDiskProcessEvents(
            events,
            snapshotID: snapshotID
        )
        guard savedCount == events.count else {
            throw RuntimeError.persistence(
                "pending disk events were not persisted"
            )
        }
    }

    func performMaintenance(now: Date) throws -> DatabaseMaintenanceReport {
        try database.performMaintenance(now: now)
    }

    func checkpoint() throws -> Bool {
        try database.checkpoint()
    }

    func close() {
        database.close()
    }
}

final class MonitoringRuntime {
    let configuration: RuntimeConfiguration

    private let collector: RuntimeSnapshotCollector
    private let fsUsage: RuntimeFSUsageSource
    private let detection: RuntimeDetectionEngine
    private let persistence: RuntimePersistence
    private let waiter: RuntimeWaiter
    private let clock: RuntimeClock
    private let logger: RuntimeLogging
    private let statusReporter: RuntimeStatusReporting

    private let condition = NSCondition()
    private var stateValue: RuntimeState = .stopped
    private var hasStarted = false
    private var didFinish = false
    private var isFinishing = false
    private var isRunning = false
    private var runThread: Thread?
    private var stopRequested = false
    private var didLogStopRequest = false
    private var previousDroppedEventCount = 0
    private var lastFSUsageDiagnostic: String?
    private var lastCollectedSnapshot: SystemSnapshot?
    private var lastPersistedSnapshotID: Int64?
    private var pendingSnapshot: SystemSnapshot?
    private var pendingDiskEvents: [DiskProcessEvent] = []
    private var metrics = RuntimeCycleMetrics()

    init(
        configuration: RuntimeConfiguration = .standard,
        collector: RuntimeSnapshotCollector,
        fsUsage: RuntimeFSUsageSource,
        detection: RuntimeDetectionEngine,
        persistence: RuntimePersistence,
        waiter: RuntimeWaiter = InterruptibleRuntimeWaiter(),
        clock: RuntimeClock = SystemRuntimeClock(),
        logger: RuntimeLogging = RuntimeLogger(),
        statusReporter: RuntimeStatusReporting = NoopRuntimeStatusReporter()
    ) {
        self.configuration = configuration
        self.collector = collector
        self.fsUsage = fsUsage
        self.detection = detection
        self.persistence = persistence
        self.waiter = waiter
        self.clock = clock
        self.logger = logger
        self.statusReporter = statusReporter
    }

    var state: RuntimeState {
        condition.lock()
        defer { condition.unlock() }
        return stateValue
    }

    var metricsSnapshot: RuntimeCycleMetrics {
        condition.lock()
        defer { condition.unlock() }
        return metrics
    }

    @discardableResult
    func start() -> Bool {
        condition.lock()
        guard !hasStarted, stateValue == .stopped else {
            condition.unlock()
            return false
        }

        hasStarted = true
        stateValue = .running
        stopRequested = false
        didLogStopRequest = false
        metrics = RuntimeCycleMetrics()
        condition.unlock()

        do {
            do {
                try persistence.start()
            } catch {
                throw normalize(error, fallback: .persistence("persistence startup failed"))
            }
            do {
                try collector.start()
            } catch {
                throw normalize(error, fallback: .collection("collector startup failed"))
            }
            do {
                try fsUsage.start()
            } catch {
                throw normalize(error, fallback: .fsUsage("fs_usage startup failed"))
            }
            let startupDiagnostic = fsUsage.diagnostic
            reportFSUsageDiagnostic()
            if startupDiagnostic == nil {
                logger.log(
                    .info,
                    "Monitoring runtime started",
                    context: RuntimeLogContext(timestamp: clock.now)
                )
            } else {
                logger.log(
                    .warning,
                    "Monitoring runtime started with degraded fs_usage",
                    context: RuntimeLogContext(
                        timestamp: clock.now,
                        errorType: "fs_usage"
                    )
                )
            }
            publishStatus(for: .running)
            return true
        } catch {
            let runtimeError: RuntimeError
            if let typedError = error as? RuntimeError {
                runtimeError = typedError
            } else {
                runtimeError = .fatal(String(describing: error))
            }
            condition.lock()
            stateValue = .failed(runtimeError.description)
            metrics.fatalErrors += 1
            condition.unlock()
            logger.log(
                .error,
                "Monitoring runtime failed to start",
                context: RuntimeLogContext(
                    timestamp: clock.now,
                    errorType: runtimeError.category
                )
            )
            finish(finalState: .failed(runtimeError.description))
            return false
        }
    }

    func run() {
        condition.lock()
        guard hasStarted, !didFinish, !isFinishing, !isRunning else {
            condition.unlock()
            return
        }

        if stateValue == .stopping || stopRequested {
            condition.unlock()
            finish(finalState: .stopped)
            return
        }
        guard stateValue == .running else {
            condition.unlock()
            return
        }

        isRunning = true
        runThread = Thread.current
        condition.unlock()

        var fatalError: RuntimeError?
        var completedInitialWait = !collector.waitsBeforeFirstCycle
        while true {
            if shouldStop() {
                break
            }

            if !completedInitialWait {
                waiter.wait(for: configuration.samplingInterval)
                if shouldStop() {
                    break
                }
                completedInitialWait = true
            }

            if let error = runCycle(), error.isFatal {
                fatalError = error
                break
            }

            if shouldStop() {
                break
            }
            waiter.wait(for: configuration.samplingInterval)
        }

        if let fatalError {
            finish(finalState: .failed(fatalError.description))
        } else {
            finish(finalState: .stopped)
        }
    }

    func requestStop() {
        condition.lock()
        guard hasStarted, !didFinish, !isFinishing else {
            condition.unlock()
            return
        }

        stopRequested = true
        if stateValue == .running {
            stateValue = .stopping
        }
        let shouldWake = stateValue == .stopping
        let shouldLog = !didLogStopRequest
        didLogStopRequest = true
        condition.unlock()

        if shouldWake {
            waiter.wake()
        }
        if shouldLog {
            logger.log(
                .info,
                "Shutdown requested",
                context: RuntimeLogContext(timestamp: clock.now)
            )
        }
        publishStatus(for: .stopping)
    }

    func stop() {
        requestStop()

        condition.lock()
        let shouldWait = (isRunning || isFinishing) &&
            runThread !== Thread.current
        if shouldWait {
            while !didFinish {
                condition.wait()
            }
        }
        let shouldFinish = !isRunning && !isFinishing && !didFinish
        condition.unlock()

        if shouldFinish {
            finish(finalState: .stopped)
        }
    }

    func waitUntilStopped() {
        condition.lock()
        if runThread === Thread.current {
            condition.unlock()
            return
        }
        while hasStarted && !didFinish {
            condition.wait()
        }
        condition.unlock()
    }

    deinit {
        requestStop()
        condition.lock()
        let shouldFinish = !isRunning && !isFinishing && !didFinish
        condition.unlock()
        if shouldFinish {
            finish(finalState: .stopped)
        }
    }

    private func shouldStop() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return stopRequested || stateValue == .stopping
    }

    private func publishStatus(for requestedState: RuntimeState? = nil) {
        condition.lock()
        let state = requestedState ?? stateValue
        let metrics = self.metrics
        condition.unlock()

        let diagnostic = self.fsUsage.diagnostic
        let fsUsage = RuntimeFSUsageStatusPayload(
            state: self.fsUsage.stateName,
            diagnostic: diagnostic,
            permissionDenied: diagnostic?.lowercased().contains("permission") == true,
            stderr: diagnostic,
            droppedEvents: self.fsUsage.droppedEventCount
        )
        statusReporter.publish(
            RuntimeStatusPayload(
                version: 1,
                state: stateName(for: state),
                updatedAt: clock.now,
                cyclesExecuted: metrics.cyclesExecuted,
                lastCycleAt: metrics.lastCycleAt,
                lastSuccessfulPersistenceAt: metrics.lastSuccessfulPersistenceAt,
                lastMaintenanceAt: metrics.lastMaintenanceAt,
                fsUsage: fsUsage
            )
        )
    }

    private func stateName(for state: RuntimeState) -> String {
        switch state {
        case .stopped:
            return "stopped"
        case .running:
            return "running"
        case .stopping:
            return "stopping"
        case .failed:
            return "failed"
        }
    }

    private func runCycle() -> RuntimeError? {
        condition.lock()
        guard !stopRequested, stateValue == .running else {
            condition.unlock()
            return nil
        }
        metrics.cyclesExecuted += 1
        let cycle = metrics.cyclesExecuted
        condition.unlock()

        let startedAt = clock.now
        let currentDroppedEventCount = fsUsage.droppedEventCount
        var cycleFatalError: RuntimeError?
        var snapshotID: Int64?
        var eventCount = 0

        defer {
            let finishedAt = clock.now
            condition.lock()
            metrics.lastCycleAt = finishedAt
            metrics.lastCycleDuration = finishedAt.timeIntervalSince(startedAt)
            condition.unlock()
            publishStatus()
            logger.log(
                .debug,
                "Monitoring cycle finished",
                context: RuntimeLogContext(
                    cycle: cycle,
                    timestamp: finishedAt,
                    snapshotID: snapshotID,
                    eventCount: eventCount,
                    duration: finishedAt.timeIntervalSince(startedAt)
                )
            )
        }

        let snapshot: SystemSnapshot
        do {
            let droppedEvents = max(
                0,
                currentDroppedEventCount - previousDroppedEventCount
            )
            snapshot = try collector.collect(droppedEvents: droppedEvents)
            condition.lock()
            lastCollectedSnapshot = snapshot
            condition.unlock()
        } catch {
            return cycleFailure(
                error,
                fallback: .collection("snapshot collection failed"),
                cycle: cycle,
                snapshotID: snapshotID,
                eventCount: eventCount,
                startedAt: startedAt
            )
        }

        var diskEvents: [DiskProcessEvent]
        do {
            reportFSUsageDiagnostic()
            diskEvents = try fsUsage.getBufferedEvents()
            let existingPending = pendingEventsSnapshot()
            if !diskEvents.isEmpty {
                diskEvents = mergePendingEvents(
                    existingPending.events,
                    diskEvents
                )
                setPendingEvents(snapshot: snapshot, events: diskEvents)
            } else if !existingPending.events.isEmpty {
                diskEvents = existingPending.events
                setPendingEvents(snapshot: snapshot, events: diskEvents)
            }
            eventCount = diskEvents.count
        } catch {
            return cycleFailure(
                error,
                fallback: .fsUsage("fs_usage event collection failed"),
                cycle: cycle,
                snapshotID: snapshotID,
                eventCount: eventCount,
                startedAt: startedAt
            )
        }

        let detectedEvents: [DetectedEvent]
        do {
            detectedEvents = try detection.detect(snapshot: snapshot)
        } catch {
            return cycleFailure(
                error,
                fallback: .detection("detection failed"),
                cycle: cycle,
                snapshotID: snapshotID,
                eventCount: eventCount,
                startedAt: startedAt
            )
        }

        do {
            let persistedSnapshotID = try persistence.save(
                snapshot: snapshot,
                diskProcessEvents: diskEvents
            )
            snapshotID = persistedSnapshotID
            guard fsUsage.acknowledgeBufferedEvents(diskEvents) else {
                throw RuntimeError.fsUsage(
                    "fs_usage batch acknowledgement failed"
                )
            }
            clearPendingEvents()
            previousDroppedEventCount = currentDroppedEventCount
            condition.lock()
            lastPersistedSnapshotID = persistedSnapshotID
            metrics.lastSuccessfulPersistenceAt = clock.now
            condition.unlock()

            if cycle == 1 || cycle % 30 == 0 {
                logger.log(
                    .info,
                    String(
                        format: "sample cpu=%.1f%% memory=%.1f%% disk_read=%.1fMB/s disk_write=%.1fMB/s",
                        snapshot.cpu,
                        snapshot.memory,
                        snapshot.diskRead / 1_000_000,
                        snapshot.diskWrite / 1_000_000
                    ),
                    context: RuntimeLogContext(
                        cycle: cycle,
                        timestamp: snapshot.timestamp,
                        snapshotID: persistedSnapshotID,
                        eventCount: diskEvents.count,
                        duration: clock.now.timeIntervalSince(startedAt)
                    )
                )
            }
        } catch {
            return cycleFailure(
                error,
                fallback: .persistence("snapshot persistence failed"),
                cycle: cycle,
                snapshotID: snapshotID,
                eventCount: eventCount,
                startedAt: startedAt
            )
        }

        for event in detectedEvents {
            do {
                try persistence.save(
                    event: event,
                    snapshotID: snapshotID!,
                    timestamp: snapshot.timestamp
                )
                logger.log(
                    .warning,
                    "\(event.type): \(event.message)",
                    context: RuntimeLogContext(
                        cycle: cycle,
                        timestamp: snapshot.timestamp,
                        snapshotID: snapshotID,
                        eventCount: diskEvents.count,
                        errorType: event.severity
                    )
                )
            } catch {
                let runtimeError = normalize(
                    error,
                    fallback: .persistence("detection event was not persisted")
                )
                record(
                    runtimeError,
                    cycle: cycle,
                    snapshotID: snapshotID,
                    eventCount: eventCount,
                    startedAt: startedAt
                )
                if runtimeError.isFatal {
                    cycleFatalError = runtimeError
                }
            }
        }

        let maintenanceDate = clock.now
        condition.lock()
        let lastMaintenanceAt = metrics.lastMaintenanceAt
        condition.unlock()
        if lastMaintenanceAt == nil ||
            maintenanceDate.timeIntervalSince(lastMaintenanceAt!) >=
                configuration.maintenanceInterval {
            do {
                let report = try persistence.performMaintenance(
                    now: maintenanceDate
                )
                condition.lock()
                metrics.lastMaintenanceAt = maintenanceDate
                condition.unlock()
                if report.remainingDirtyBuckets > 0 {
                    logger.log(
                        .warning,
                        "Database maintenance has dirty buckets pending: \(report.remainingDirtyBuckets)",
                        context: RuntimeLogContext(
                            cycle: cycle,
                            timestamp: maintenanceDate,
                            snapshotID: snapshotID,
                            eventCount: eventCount,
                            duration: clock.now.timeIntervalSince(startedAt),
                            errorType: "maintenance_backlog"
                        )
                    )
                } else {
                    logger.log(
                        .debug,
                        "Database maintenance completed",
                        context: RuntimeLogContext(
                            cycle: cycle,
                            timestamp: maintenanceDate,
                            snapshotID: snapshotID,
                            eventCount: eventCount,
                            duration: clock.now.timeIntervalSince(startedAt)
                        )
                    )
                }
            } catch {
                let runtimeError = normalize(
                    error,
                    fallback: .maintenance("maintenance failed")
                )
                record(
                    runtimeError,
                    cycle: cycle,
                    snapshotID: snapshotID,
                    eventCount: eventCount,
                    startedAt: startedAt
                )
                if runtimeError.isFatal {
                    cycleFatalError = runtimeError
                }
            }
        }

        do {
            if try !persistence.checkpoint() {
                let checkpointError = RuntimeError.checkpoint(
                    "WAL checkpoint incomplete"
                )
                record(
                    checkpointError,
                    cycle: cycle,
                    snapshotID: snapshotID,
                    eventCount: eventCount,
                    startedAt: startedAt
                )
            }
        } catch {
            let runtimeError = normalize(
                error,
                fallback: .checkpoint("checkpoint failed")
            )
            record(
                runtimeError,
                cycle: cycle,
                snapshotID: snapshotID,
                eventCount: eventCount,
                startedAt: startedAt
            )
            if runtimeError.isFatal {
                cycleFatalError = runtimeError
            }
        }

        return cycleFatalError
    }

    private func cycleFailure(
        _ error: Error,
        fallback: RuntimeError,
        cycle: Int,
        snapshotID: Int64?,
        eventCount: Int,
        startedAt: Date
    ) -> RuntimeError? {
        let runtimeError = normalize(error, fallback: fallback)
        record(
            runtimeError,
            cycle: cycle,
            snapshotID: snapshotID,
            eventCount: eventCount,
            startedAt: startedAt
        )
        return runtimeError.isFatal ? runtimeError : nil
    }

    private func reportFSUsageDiagnostic() {
        let diagnostic = fsUsage.diagnostic
        condition.lock()
        let changed = diagnostic != lastFSUsageDiagnostic
        lastFSUsageDiagnostic = diagnostic
        condition.unlock()

        guard changed, let diagnostic else {
            return
        }
        logger.log(
            .warning,
            "fs_usage: \(diagnostic)",
            context: RuntimeLogContext(
                timestamp: clock.now,
                errorType: "fs_usage"
            )
        )
    }

    private func setPendingEvents(
        snapshot: SystemSnapshot,
        events: [DiskProcessEvent]
    ) {
        condition.lock()
        pendingSnapshot = snapshot
        pendingDiskEvents = events
        condition.unlock()
    }

    private func clearPendingEvents() {
        condition.lock()
        pendingSnapshot = nil
        pendingDiskEvents.removeAll(keepingCapacity: false)
        condition.unlock()
    }

    private func pendingEventsSnapshot() -> (
        snapshot: SystemSnapshot?,
        events: [DiskProcessEvent]
    ) {
        condition.lock()
        defer { condition.unlock() }
        return (pendingSnapshot, pendingDiskEvents)
    }

    private func mergePendingEvents(
        _ existing: [DiskProcessEvent],
        _ incoming: [DiskProcessEvent]
    ) -> [DiskProcessEvent] {
        var merged = existing
        for event in incoming {
            let alreadyIncluded = merged.contains { candidate in
                if event.sequence != 0 || candidate.sequence != 0 {
                    return event.sequence == candidate.sequence
                }
                return candidate == event
            }
            if !alreadyIncluded {
                merged.append(event)
            }
        }
        return merged
    }

    private func flushPendingEventsIfNeeded() -> RuntimeError? {
        condition.lock()
        let storedSnapshot = pendingSnapshot
        let storedEvents = pendingDiskEvents
        let fallbackSnapshot = lastCollectedSnapshot
        let lastPersistedID = lastPersistedSnapshotID
        let cycle = metrics.cyclesExecuted
        condition.unlock()

        guard !storedEvents.isEmpty || fallbackSnapshot != nil else {
            return nil
        }

        var events = storedEvents
        do {
            let bufferedEvents = try fsUsage.getBufferedEvents()
            if !bufferedEvents.isEmpty {
                events = mergePendingEvents(storedEvents, bufferedEvents)
            }
        } catch {
            if storedEvents.isEmpty {
                logger.log(
                    .warning,
                    "Could not inspect fs_usage events during shutdown",
                    context: RuntimeLogContext(
                        cycle: cycle,
                        timestamp: clock.now,
                        errorType: "fs_usage"
                    )
                )
                return nil
            }
        }

        guard !events.isEmpty else {
            return nil
        }

        if !storedEvents.isEmpty {
            guard let snapshot = storedSnapshot ?? fallbackSnapshot else {
                logger.log(
                    .warning,
                    "Unpersisted fs_usage events could not be flushed during shutdown",
                    context: RuntimeLogContext(
                        cycle: cycle,
                        timestamp: clock.now,
                        eventCount: events.count,
                        errorType: "fs_usage"
                    )
                )
                return nil
            }

            do {
                let persistedSnapshotID = try persistence.save(
                    snapshot: snapshot,
                    diskProcessEvents: events
                )
                guard fsUsage.acknowledgeBufferedEvents(events) else {
                    throw RuntimeError.fsUsage(
                        "fs_usage batch acknowledgement failed"
                    )
                }
                clearPendingEvents()
                condition.lock()
                lastPersistedSnapshotID = persistedSnapshotID
                metrics.lastSuccessfulPersistenceAt = clock.now
                condition.unlock()
                logger.log(
                    .info,
                    "Unpersisted fs_usage events flushed during shutdown",
                    context: RuntimeLogContext(
                        cycle: cycle,
                        timestamp: clock.now,
                        snapshotID: persistedSnapshotID,
                        eventCount: events.count
                    )
                )
            } catch {
                let runtimeError = normalize(
                    error,
                    fallback: .persistence("shutdown fs_usage flush failed")
                )
                record(
                    runtimeError,
                    cycle: cycle,
                    snapshotID: nil,
                    eventCount: events.count,
                    startedAt: clock.now
                )
                return runtimeError.isFatal ? runtimeError : nil
            }
        } else {
            guard let lastPersistedID else {
                logger.log(
                    .warning,
                    "Late fs_usage events could not be linked to a persisted snapshot",
                    context: RuntimeLogContext(
                        cycle: cycle,
                        timestamp: clock.now,
                        eventCount: events.count,
                        errorType: "fs_usage"
                    )
                )
                return nil
            }

            do {
                try persistence.savePendingDiskProcessEvents(
                    events,
                    snapshotID: lastPersistedID
                )
                guard fsUsage.acknowledgeBufferedEvents(events) else {
                    throw RuntimeError.fsUsage(
                        "fs_usage batch acknowledgement failed"
                    )
                }
                clearPendingEvents()
                condition.lock()
                metrics.lastSuccessfulPersistenceAt = clock.now
                condition.unlock()
                logger.log(
                    .info,
                    "Late fs_usage events flushed during shutdown",
                    context: RuntimeLogContext(
                        cycle: cycle,
                        timestamp: clock.now,
                        snapshotID: lastPersistedID,
                        eventCount: events.count
                    )
                )
            } catch {
                let runtimeError = normalize(
                    error,
                    fallback: .persistence("late fs_usage flush failed")
                )
                record(
                    runtimeError,
                    cycle: cycle,
                    snapshotID: lastPersistedID,
                    eventCount: events.count,
                    startedAt: clock.now
                )
                return runtimeError.isFatal ? runtimeError : nil
            }
        }

        return nil
    }

    private func record(
        _ error: RuntimeError,
        cycle: Int,
        snapshotID: Int64?,
        eventCount: Int,
        startedAt: Date
    ) {
        condition.lock()
        if error.isFatal {
            metrics.fatalErrors += 1
        } else {
            metrics.recoverableErrors += 1
        }
        condition.unlock()

        let context = RuntimeLogContext(
            cycle: cycle,
            timestamp: clock.now,
            snapshotID: snapshotID,
            eventCount: eventCount,
            duration: clock.now.timeIntervalSince(startedAt),
            errorType: error.category
        )
        let level: RuntimeLogLevel
        switch error {
        case .maintenance, .checkpoint:
            level = .warning
        default:
            level = .error
        }
        logger.log(
            level,
            error.description,
            context: context
        )
    }

    private func normalize(
        _ error: Error,
        fallback: RuntimeError
    ) -> RuntimeError {
        if let runtimeError = error as? RuntimeError {
            return runtimeError
        }
        switch fallback {
        case .collection:
            return .collection(String(describing: error))
        case .fsUsage:
            return .fsUsage(String(describing: error))
        case .detection:
            return .detection(String(describing: error))
        case .persistence:
            return .persistence(String(describing: error))
        case .maintenance:
            return .maintenance(String(describing: error))
        case .checkpoint:
            return .checkpoint(String(describing: error))
        case .fatal:
            return .fatal(String(describing: error))
        }
    }

    private func finish(finalState: RuntimeState) {
        condition.lock()
        guard !didFinish, !isFinishing else {
            condition.unlock()
            return
        }

        isFinishing = true
        if runThread == nil {
            runThread = Thread.current
        }
        if case .failed = stateValue {
        } else {
            stateValue = .stopping
        }
        condition.broadcast()
        condition.unlock()

        // Stop the producer before reading its final buffer so events emitted
        // during shutdown cannot race past the final flush.
        fsUsage.stop()
        let flushError = flushPendingEventsIfNeeded()
        collector.stop()
        persistence.close()

        let effectiveFinalState: RuntimeState
        if let flushError, flushError.isFatal, !finalState.isFailure {
            effectiveFinalState = .failed(flushError.description)
        } else {
            effectiveFinalState = finalState
        }

        condition.lock()
        didFinish = true
        isFinishing = false
        isRunning = false
        runThread = nil
        stateValue = effectiveFinalState
        condition.broadcast()
        condition.unlock()
        publishStatus(for: effectiveFinalState)

        logger.log(
            effectiveFinalState.isFailure ? .error : .info,
            effectiveFinalState.isFailure
                ? "Monitoring runtime stopped after failure"
                : "Monitoring runtime stopped",
            context: RuntimeLogContext(timestamp: clock.now)
        )
    }
}

private extension RuntimeState {
    var isFailure: Bool {
        if case .failed = self {
            return true
        }
        return false
    }
}

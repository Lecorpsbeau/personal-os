import Foundation
import Testing
@testable import mac_detective

final class RuntimeTestClock: RuntimeClock {
    var now: Date

    init(now: Date = Date(timeIntervalSince1970: 1_900_000_000)) {
        self.now = now
    }

    func advance(_ interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}

final class RuntimeTestWaiter: RuntimeWaiter {
    var intervals: [TimeInterval] = []
    var wakeCount = 0
    var onWait: ((Int) -> Void)?

    func wait(for interval: TimeInterval) {
        intervals.append(interval)
        onWait?(intervals.count)
    }

    func wake() {
        wakeCount += 1
    }
}

final class RuntimeTestCollector: RuntimeSnapshotCollector {
    var snapshots: [SystemSnapshot] = []
    var startError: Error?
    var collectError: Error?
    var onCollect: (() -> Void)?
    var waitsBeforeFirstCycle = false
    var startCount = 0
    var stopCount = 0
    var collectCount = 0

    func start() throws {
        startCount += 1
        if let startError {
            throw startError
        }
    }

    func collect(droppedEvents: Int) throws -> SystemSnapshot {
        collectCount += 1
        onCollect?()
        if let collectError {
            throw collectError
        }
        if snapshots.isEmpty {
            return RuntimeTestSupport.snapshot(droppedEvents: droppedEvents)
        }
        let index = min(collectCount - 1, snapshots.count - 1)
        return snapshots[index]
    }

    func stop() {
        stopCount += 1
    }
}

final class RuntimeTestFSUsage: RuntimeFSUsageSource {
    var events: [DiskProcessEvent] = []
    var droppedEventCount = 0
    var diagnosticValue: String?
    var startError: Error?
    var readError: Error?
    var startCount = 0
    var stopCount = 0
    var readCount = 0
    var acknowledgements: [Int] = []

    var diagnostic: String? { diagnosticValue }

    func start() throws {
        startCount += 1
        if let startError {
            throw startError
        }
    }

    func stop() {
        stopCount += 1
    }

    func getBufferedEvents() throws -> [DiskProcessEvent] {
        readCount += 1
        if let readError {
            throw readError
        }
        return events
    }

    func acknowledgeBufferedEvents(count: Int) {
        guard count > 0 else {
            return
        }
        acknowledgements.append(count)
        events.removeFirst(min(count, events.count))
    }
}

final class RuntimeTestDetection: RuntimeDetectionEngine {
    var events: [DetectedEvent] = []
    var error: Error?
    var callCount = 0

    func detect(snapshot: SystemSnapshot) throws -> [DetectedEvent] {
        callCount += 1
        if let error {
            throw error
        }
        return events
    }
}

final class RuntimeTestPersistence: RuntimePersistence {
    var saveFailuresRemaining = 0
    var saveEventFailuresRemaining = 0
    var maintenanceFailuresRemaining = 0
    var checkpointResult = true
    var checkpointError: Error?
    var startCount = 0
    var saveCount = 0
    var saveEventCount = 0
    var pendingSaveCount = 0
    var maintenanceCount = 0
    var checkpointCount = 0
    var closeCount = 0
    var savedSnapshots: [SystemSnapshot] = []
    var savedDiskEventCounts: [Int] = []

    func start() throws {
        startCount += 1
    }

    func save(
        snapshot: SystemSnapshot,
        diskProcessEvents: [DiskProcessEvent]
    ) throws -> Int64 {
        saveCount += 1
        if saveFailuresRemaining > 0 {
            saveFailuresRemaining -= 1
            throw RuntimeError.persistence("injected save failure")
        }
        savedSnapshots.append(snapshot)
        savedDiskEventCounts.append(diskProcessEvents.count)
        return Int64(saveCount)
    }

    func save(
        event: DetectedEvent,
        snapshotID: Int64,
        timestamp: Date
    ) throws {
        saveEventCount += 1
        if saveEventFailuresRemaining > 0 {
            saveEventFailuresRemaining -= 1
            throw RuntimeError.persistence("injected event save failure")
        }
    }

    func savePendingDiskProcessEvents(
        _ events: [DiskProcessEvent],
        snapshotID: Int64?
    ) throws {
        pendingSaveCount += events.count
    }

    func performMaintenance(now: Date) throws -> DatabaseMaintenanceReport {
        maintenanceCount += 1
        if maintenanceFailuresRemaining > 0 {
            maintenanceFailuresRemaining -= 1
            throw RuntimeError.maintenance("injected maintenance failure")
        }
        return DatabaseMaintenanceReport(
            deletedSystemSamples: 0,
            deletedProcessSamples: 0,
            deletedDiskProcessEvents: 0,
            deletedEvents: 0,
            deletedHourlySystemStats: 0,
            deletedHourlyProcessStats: 0,
            deletedDailySystemStats: 0,
            deletedDailyProcessStats: 0,
            refreshedHourlySystemStats: 0,
            refreshedHourlyProcessStats: 0,
            refreshedDailySystemStats: 0,
            refreshedDailyProcessStats: 0
        )
    }

    func checkpoint() throws -> Bool {
        checkpointCount += 1
        if let checkpointError {
            throw checkpointError
        }
        return checkpointResult
    }

    func close() {
        closeCount += 1
    }
}

final class RuntimeTestLogSink: RuntimeLogSink {
    var entries: [RuntimeLogEntry] = []

    func write(_ entry: RuntimeLogEntry) {
        entries.append(entry)
    }
}

final class RuntimeTestSignalController: RuntimeSignalInstalling {
    var handler: ((RuntimeSignal) -> Void)?
    var installCount = 0
    var cancelCount = 0

    func install(handler: @escaping (RuntimeSignal) -> Void) {
        installCount += 1
        self.handler = handler
    }

    func cancel() {
        cancelCount += 1
        handler = nil
    }

    func deliver(_ signal: RuntimeSignal) {
        handler?(signal)
    }
}

enum RuntimeTestSupport {
    static func snapshot(
        at date: Date = Date(timeIntervalSince1970: 1_900_000_000),
        droppedEvents: Int = 0
    ) -> SystemSnapshot {
        SystemSnapshot(
            timestamp: date,
            cpu: 10,
            memory: 20,
            diskRead: 30,
            diskWrite: 40,
            networkIn: 50,
            networkOut: 60,
            processes: [],
            droppedEvents: droppedEvents
        )
    }

    static func event(
        type: String = "TEST",
        message: String = "test"
    ) -> DetectedEvent {
        DetectedEvent(
            type: type,
            severity: "info",
            value: 1,
            message: message
        )
    }
}

@Suite("Monitoring Runtime Tests")
struct MonitoringRuntimeTests {

    private func makeRuntime(
        configuration: RuntimeConfiguration = try! RuntimeConfiguration(
            samplingInterval: 0.25,
            maintenanceInterval: 10,
            logLevel: .debug
        ),
        collector: RuntimeTestCollector = RuntimeTestCollector(),
        fsUsage: RuntimeTestFSUsage = RuntimeTestFSUsage(),
        detection: RuntimeTestDetection = RuntimeTestDetection(),
        persistence: RuntimeTestPersistence = RuntimeTestPersistence(),
        waiter: RuntimeTestWaiter = RuntimeTestWaiter(),
        clock: RuntimeTestClock = RuntimeTestClock(),
        sink: RuntimeTestLogSink = RuntimeTestLogSink()
    ) -> (
        MonitoringRuntime,
        RuntimeTestCollector,
        RuntimeTestFSUsage,
        RuntimeTestDetection,
        RuntimeTestPersistence,
        RuntimeTestWaiter,
        RuntimeTestLogSink
    ) {
        let logger = RuntimeLogger(
            minimumLevel: configuration.logLevel,
            sink: sink,
            clock: clock
        )
        let runtime = MonitoringRuntime(
            configuration: configuration,
            collector: collector,
            fsUsage: fsUsage,
            detection: detection,
            persistence: persistence,
            waiter: waiter,
            clock: clock,
            logger: logger
        )
        return (runtime, collector, fsUsage, detection, persistence, waiter, sink)
    }

    @Test("Lifecycle starts, stops, and tolerates repeated stop")
    func testLifecycle() {
        let fixture = makeRuntime()
        let runtime = fixture.0

        #expect(runtime.state == .stopped)
        #expect(runtime.start())
        #expect(runtime.state == .running)
        runtime.requestStop()
        #expect(runtime.state == .stopping)
        runtime.run()
        #expect(runtime.state == .stopped)
        runtime.stop()
        runtime.stop()
        #expect(runtime.state == .stopped)
        #expect(fixture.1.stopCount == 1)
        #expect(fixture.2.stopCount == 1)
        #expect(fixture.4.closeCount == 1)
    }

    @Test("Stop before start is safe")
    func testStopBeforeStart() {
        let fixture = makeRuntime()
        fixture.0.stop()
        #expect(fixture.0.state == .stopped)
        #expect(fixture.4.closeCount == 1)
    }

    @Test("Startup failure enters explicit failed state")
    func testStartupFailure() {
        let collector = RuntimeTestCollector()
        collector.startError = RuntimeError.fatal("collector unavailable")
        let fixture = makeRuntime(collector: collector)

        #expect(!fixture.0.start())
        #expect(fixture.0.state == .failed("fatal: collector unavailable"))
        #expect(fixture.0.metricsSnapshot.fatalErrors == 1)
        #expect(fixture.1.stopCount == 1)
        #expect(fixture.4.closeCount == 1)
    }

    @Test("Successful cycles persist, acknowledge, and stop during wait")
    func testSuccessfulCycles() {
        let fixture = makeRuntime()
        fixture.1.snapshots = [
            RuntimeTestSupport.snapshot(),
            RuntimeTestSupport.snapshot(),
            RuntimeTestSupport.snapshot()
        ]
        fixture.2.events = [
            DiskProcessEvent(
                timestamp: Date(),
                operation: "W",
                bytes: 10,
                processName: "test",
                pid: 1
            )
        ]
        fixture.5.onWait = { [weak runtime = fixture.0] count in
            if count == 3 {
                runtime?.requestStop()
            }
        }

        #expect(fixture.0.start())
        fixture.0.run()

        #expect(fixture.0.state == .stopped)
        #expect(fixture.1.collectCount == 3)
        #expect(fixture.4.saveCount == 3)
        #expect(fixture.2.acknowledgements == [1])
        #expect(fixture.5.intervals == [0.25, 0.25, 0.25])
        #expect(fixture.0.metricsSnapshot.cyclesExecuted == 3)
        #expect(fixture.0.metricsSnapshot.lastSuccessfulPersistenceAt != nil)
    }

    @Test("Live-style collectors wait one interval after baseline warmup")
    func testInitialSamplingDelay() {
        let fixture = makeRuntime()
        fixture.1.waitsBeforeFirstCycle = true
        fixture.5.onWait = { [weak runtime = fixture.0] count in
            if count == 2 {
                runtime?.requestStop()
            }
        }

        fixture.0.start()
        fixture.0.run()

        #expect(fixture.1.collectCount == 1)
        #expect(fixture.5.intervals == [0.25, 0.25])
    }

    @Test("Persistence failure never acknowledges fs_usage before retry")
    func testPersistenceFailureDoesNotAcknowledge() {
        let fixture = makeRuntime()
        fixture.2.events = [
            DiskProcessEvent(
                timestamp: Date(),
                operation: "R",
                bytes: 20,
                processName: "test",
                pid: 2
            )
        ]
        fixture.4.saveFailuresRemaining = 1
        fixture.5.onWait = { [weak runtime = fixture.0] count in
            if count == 2 {
                runtime?.requestStop()
            }
        }

        fixture.0.start()
        fixture.0.run()

        #expect(fixture.2.acknowledgements == [1])
        #expect(fixture.0.metricsSnapshot.recoverableErrors == 1)
        #expect(fixture.4.saveCount == 2)
    }

    @Test("Shutdown flushes known fs_usage events after a failed persistence cycle")
    func testShutdownFlushesPendingEvents() {
        let fixture = makeRuntime()
        fixture.2.events = [
            DiskProcessEvent(
                timestamp: Date(),
                operation: "R",
                bytes: 40,
                processName: "pending",
                pid: 9
            )
        ]
        fixture.4.saveFailuresRemaining = 1
        fixture.5.onWait = { [weak runtime = fixture.0] _ in
            runtime?.requestStop()
        }

        fixture.0.start()
        fixture.0.run()

        #expect(fixture.4.saveCount == 2)
        #expect(fixture.2.acknowledgements == [1])
        #expect(fixture.2.events.isEmpty)
        #expect(fixture.0.metricsSnapshot.recoverableErrors == 1)
    }

    @Test("Shutdown flushes fs_usage events that arrive during the final wait")
    func testShutdownFlushesEventsArrivingDuringWait() {
        let fixture = makeRuntime()
        fixture.5.onWait = { [weak runtime = fixture.0] _ in
            fixture.2.events = [
                DiskProcessEvent(
                    timestamp: Date(),
                    operation: "W",
                    bytes: 50,
                    processName: "late",
                    pid: 10
                )
            ]
            runtime?.requestStop()
        }

        fixture.0.start()
        fixture.0.run()

        #expect(fixture.4.saveCount == 1)
        #expect(fixture.4.savedSnapshots.count == 1)
        #expect(fixture.4.pendingSaveCount == 1)
        #expect(fixture.2.acknowledgements == [1])
        #expect(fixture.2.events.isEmpty)
    }

    @Test("Pending fs_usage batches are merged after an overflow")
    func testPendingBatchMerge() {
        let fixture = makeRuntime()
        fixture.2.events = [
            DiskProcessEvent(
                timestamp: Date(),
                operation: "R",
                bytes: 60,
                processName: "old",
                pid: 11
            )
        ]
        fixture.4.saveFailuresRemaining = 1
        fixture.5.onWait = { [weak runtime = fixture.0] count in
            if count == 1 {
                fixture.2.events = [
                    DiskProcessEvent(
                        timestamp: Date(),
                        operation: "W",
                        bytes: 70,
                        processName: "new",
                        pid: 12
                    )
                ]
            } else if count == 2 {
                runtime?.requestStop()
            }
        }

        fixture.0.start()
        fixture.0.run()

        #expect(fixture.4.savedDiskEventCounts == [2])
        #expect(fixture.2.acknowledgements == [2])
    }

    @Test("fs_usage read failure is recoverable and does not persist or acknowledge")
    func testFSUsageFailure() {
        let fixture = makeRuntime()
        fixture.2.readError = RuntimeError.fsUsage("pipe unavailable")
        fixture.5.onWait = { [weak runtime = fixture.0] _ in
            runtime?.requestStop()
        }

        fixture.0.start()
        fixture.0.run()

        #expect(fixture.4.saveCount == 0)
        #expect(fixture.2.acknowledgements.isEmpty)
        #expect(fixture.0.metricsSnapshot.recoverableErrors == 1)
    }

    @Test("Maintenance interval is respected and failed maintenance retries")
    func testMaintenanceIntervalAndRetry() {
        let clock = RuntimeTestClock()
        let fixture = makeRuntime(clock: clock)
        fixture.4.maintenanceFailuresRemaining = 1
        fixture.1.onCollect = {
            clock.advance(1)
        }
        fixture.5.onWait = { [weak runtime = fixture.0] count in
            if count == 3 {
                runtime?.requestStop()
            }
        }

        fixture.0.start()
        fixture.0.run()

        #expect(fixture.4.maintenanceCount == 2)
        #expect(fixture.0.metricsSnapshot.recoverableErrors == 1)
        #expect(fixture.0.metricsSnapshot.lastMaintenanceAt != nil)
    }

    @Test("Detection failure is recoverable and does not acknowledge fs_usage")
    func testDetectionFailure() {
        let fixture = makeRuntime()
        fixture.2.events = [
            DiskProcessEvent(
                timestamp: Date(),
                operation: "W",
                bytes: 30,
                processName: "test",
                pid: 3
            )
        ]
        fixture.3.error = RuntimeError.detection("detector unavailable")
        fixture.5.onWait = { [weak runtime = fixture.0] _ in
            runtime?.requestStop()
        }

        fixture.0.start()
        fixture.0.run()

        #expect(fixture.4.saveCount == 1)
        #expect(fixture.2.acknowledgements == [1])
        #expect(fixture.0.metricsSnapshot.recoverableErrors == 1)
        #expect(fixture.6.entries.contains { $0.context.errorType == "detection" })
    }

    @Test("Detection event persistence failure is recoverable")
    func testDetectionEventPersistenceFailure() {
        let fixture = makeRuntime()
        fixture.3.events = [RuntimeTestSupport.event()]
        fixture.4.saveEventFailuresRemaining = 1
        fixture.5.onWait = { [weak runtime = fixture.0] _ in
            runtime?.requestStop()
        }

        fixture.0.start()
        fixture.0.run()

        #expect(fixture.0.state == .stopped)
        #expect(fixture.0.metricsSnapshot.recoverableErrors == 1)
        #expect(fixture.6.entries.contains { $0.context.errorType == "persistence" })
    }

    @Test("Recoverable collection failure allows the next cycle to continue")
    func testRecoverableCollectionFailure() {
        let fixture = makeRuntime()
        fixture.1.collectError = RuntimeError.collection("temporary sample failure")
        fixture.1.snapshots = [
            RuntimeTestSupport.snapshot(),
            RuntimeTestSupport.snapshot()
        ]
        fixture.5.onWait = { [weak runtime = fixture.0] count in
            if count == 2 {
                runtime?.requestStop()
            }
        }

        fixture.0.start()
        fixture.0.run()

        #expect(fixture.0.metricsSnapshot.recoverableErrors == 2)
        #expect(fixture.4.saveCount == 0)
        #expect(fixture.0.state == .stopped)
    }

    @Test("Checkpoint failure is logged as recoverable")
    func testCheckpointFailure() {
        let fixture = makeRuntime()
        fixture.4.checkpointResult = false
        fixture.5.onWait = { [weak runtime = fixture.0] _ in
            runtime?.requestStop()
        }

        fixture.0.start()
        fixture.0.run()

        #expect(fixture.0.metricsSnapshot.recoverableErrors == 1)
        #expect(fixture.6.entries.contains { $0.context.errorType == "checkpoint" })
    }

    @Test("Database close is idempotent")
    func testDatabaseCloseIsIdempotent() throws {
        let path = NSTemporaryDirectory() + "runtime-close-\(UUID().uuidString).sqlite"
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + "-wal")
            try? FileManager.default.removeItem(atPath: path + "-shm")
        }
        let database = Database(databasePath: path, logWrites: false)
        #expect(database.close())
        #expect(database.close())
    }

    @Test("Database event adapter propagates persistence errors")
    func testDatabaseEventAdapterPropagatesError() throws {
        let database = Database(databasePath: ":memory:", logWrites: false)
        let snapshot = RuntimeTestSupport.snapshot()
        let snapshotID = try #require(database.save(snapshot: snapshot))
        database.close()

        let persistence = DatabaseRuntimePersistence(database: database)
        var didThrow = false
        do {
            try persistence.save(
                event: RuntimeTestSupport.event(),
                snapshotID: snapshotID,
                timestamp: snapshot.timestamp
            )
        } catch {
            didThrow = true
        }
        #expect(didThrow)
    }

    @Test("Runtime refuses to start with an unready database")
    func testUnreadyDatabase() throws {
        let path = NSTemporaryDirectory() + "runtime-unready-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: path) }

        let database = Database(databasePath: path, logWrites: false)
        #expect(!database.isReady)
        let persistence = DatabaseRuntimePersistence(database: database)
        #expect(throws: RuntimeError.persistence("database is not ready")) {
            try persistence.start()
        }
    }

    @Test("Fatal cycle error stops the runtime and records a fatal metric")
    func testFatalError() {
        let fixture = makeRuntime()
        fixture.1.collectError = RuntimeError.fatal("collector crashed")

        fixture.0.start()
        fixture.0.run()

        #expect(fixture.0.state == .failed("fatal: collector crashed"))
        #expect(fixture.0.metricsSnapshot.fatalErrors == 1)
        #expect(fixture.4.saveCount == 0)
    }

    @Test("Shutdown during collection finishes current cycle but starts no next cycle")
    func testShutdownDuringCycle() {
        let fixture = makeRuntime()
        var runtime: MonitoringRuntime?
        fixture.1.onCollect = {
            runtime?.requestStop()
        }
        runtime = fixture.0
        fixture.5.onWait = { _ in
            #expect(Bool(false), "runtime must not wait after in-cycle shutdown")
        }

        fixture.0.start()
        fixture.0.run()

        #expect(fixture.1.collectCount == 1)
        #expect(fixture.4.saveCount == 1)
        #expect(fixture.2.acknowledgements.isEmpty)
        #expect(fixture.0.state == .stopped)
    }

    @Test("FS_usage acknowledgement removes the exact persisted batch")
    func testExactFSUsageAcknowledgement() {
        let collector = FSUsageCollector(maxBufferSize: 3)
        let line = { (name: String, pid: Int32) in
            "21:55:20.636784 PgOut[AP] D=0x0194580d B=0x7000 /dev/disk3s6 0.000026 W \(name).\(pid)"
        }

        collector.processOutput([
            line("batch0", 100),
            line("batch1", 101),
            line("batch2", 102)
        ].joined(separator: "\n"))
        let persistedBatch = collector.getBufferedEvents()
        #expect(persistedBatch.count == 3)

        collector.processOutput([
            line("late0", 200),
            line("late1", 201),
            line("late2", 202),
            line("late3", 203)
        ].joined(separator: "\n"))

        #expect(collector.acknowledgeBufferedEvents(persistedBatch))
        let remaining = collector.getBufferedEvents()
        #expect(remaining.map(\.processName) == ["late1", "late2", "late3"])
    }

    @Test("Interruptible waiter wakes promptly")
    func testInterruptibleWaiter() {
        let waiter = InterruptibleRuntimeWaiter()
        let startedAt = Date()
        let thread = Thread {
            waiter.wait(for: 10)
        }
        thread.start()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            waiter.wake()
        }
        while !thread.isFinished {
            Thread.sleep(forTimeInterval: 0.005)
        }
        #expect(Date().timeIntervalSince(startedAt) < 1)

        let preWokenWaiter = InterruptibleRuntimeWaiter()
        preWokenWaiter.wake()
        let preWokenAt = Date()
        preWokenWaiter.wait(for: 10)
        #expect(Date().timeIntervalSince(preWokenAt) < 1)
    }

    @Test("FS_usage health diagnostics are logged once per state")
    func testFSUsageDiagnosticLogging() {
        let fixture = makeRuntime()
        fixture.2.diagnosticValue = "permission denied"
        fixture.5.onWait = { [weak runtime = fixture.0] _ in
            runtime?.requestStop()
        }

        fixture.0.start()
        fixture.0.run()

        #expect(
            fixture.6.entries.filter {
                $0.context.errorType == "fs_usage"
            }.count >= 1
        )
    }

    @Test("Signal router buffers shutdown during bootstrap")
    func testSignalRouterBootstrap() {
        let router = RuntimeSignalRouter()
        var received: [RuntimeSignal] = []
        router.receive(.terminate)
        router.connect { signal in
            received.append(signal)
        }
        #expect(received == [.terminate])
    }

    @Test("Signal abstraction only requests shutdown")
    func testSignalAbstraction() {
        let fixture = makeRuntime()
        let signals = RuntimeTestSignalController()
        fixture.0.start()
        signals.install { signal in
            fixture.0.requestStop()
        }
        signals.deliver(.interrupt)
        #expect(fixture.0.state == .stopping)
        #expect(fixture.5.wakeCount == 1)
        signals.deliver(.terminate)
        #expect(fixture.0.state == .stopping)
        fixture.0.run()
        #expect(fixture.0.state == .stopped)
    }

    @Test("Logger filters levels and includes cycle context")
    func testLogger() {
        let fixture = makeRuntime(
            configuration: try! RuntimeConfiguration(
                samplingInterval: 0.25,
                maintenanceInterval: 10,
                logLevel: .info
            )
        )
        fixture.6.entries.removeAll()
        fixture.0.start()
        fixture.5.onWait = { [weak runtime = fixture.0] _ in
            runtime?.requestStop()
        }
        fixture.0.run()

        #expect(fixture.6.entries.contains { $0.level == .info })
        #expect(fixture.6.entries.allSatisfy { $0.level != .debug })

        let debugSink = RuntimeTestLogSink()
        let debugLogger = RuntimeLogger(
            minimumLevel: .debug,
            sink: debugSink,
            clock: RuntimeTestClock()
        )
        debugLogger.log(
            .debug,
            "cycle context",
            context: RuntimeLogContext(cycle: 7, snapshotID: 42)
        )
        #expect(debugSink.entries.first?.context.cycle == 7)
        #expect(debugSink.entries.first?.context.snapshotID == 42)
    }

    @Test("Runtime status file publishes a readable snapshot")
    func testRuntimeStatusFile() throws {
        let directory = NSTemporaryDirectory() + "runtime-status-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let url = URL(fileURLWithPath: directory)
            .appendingPathComponent("status.json")
        let store = RuntimeStatusFileStore(url: url)
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        store.publish(
            RuntimeStatusPayload(
                version: 1,
                state: "running",
                updatedAt: date,
                cyclesExecuted: 3,
                lastCycleAt: date,
                lastSuccessfulPersistenceAt: date,
                lastMaintenanceAt: nil,
                fsUsage: RuntimeFSUsageStatusPayload(
                    state: "running",
                    diagnostic: nil,
                    permissionDenied: false,
                    stderr: nil,
                    droppedEvents: 1
                )
            )
        )

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(RuntimeStatusPayload.self, from: data)
        #expect(payload.state == "running")
        #expect(payload.cyclesExecuted == 3)
        #expect(payload.fsUsage?.droppedEvents == 1)
    }

    @Test("Runtime configuration validates defaults and custom intervals")
    func testConfiguration() {
        let standard = RuntimeConfiguration.standard
        #expect(standard.samplingInterval == 2)
        #expect(standard.maintenanceInterval == 3_600)
        #expect(standard.logLevel == .info)
        #expect(standard.fsUsageEnabled)

        let custom = try! RuntimeConfiguration(
            samplingInterval: 0.5,
            maintenanceInterval: 10,
            logLevel: .warning,
            fsUsageEnabled: false
        )
        #expect(custom.samplingInterval == 0.5)
        #expect(custom.maintenanceInterval == 10)
        #expect(custom.logLevel == .warning)
        #expect(!custom.fsUsageEnabled)

        #expect(throws: RuntimeConfigurationError.invalidSamplingInterval) {
            try RuntimeConfiguration(
                samplingInterval: 0,
                maintenanceInterval: 1
            )
        }
        #expect(throws: RuntimeConfigurationError.invalidMaintenanceInterval) {
            try RuntimeConfiguration(
                samplingInterval: 1,
                maintenanceInterval: 0
            )
        }
        #expect(throws: RuntimeConfigurationError.invalidSamplingInterval) {
            try RuntimeConfiguration(
                samplingInterval: .infinity,
                maintenanceInterval: 1
            )
        }
    }

    @Test("Cycle metrics expose duration and timestamps")
    func testMetrics() {
        let clock = RuntimeTestClock()
        let fixture = makeRuntime(clock: clock)
        fixture.1.onCollect = {
            clock.advance(2)
        }
        fixture.5.onWait = { [weak runtime = fixture.0] count in
            if count == 2 {
                runtime?.requestStop()
            }
        }

        fixture.0.start()
        fixture.0.run()

        let metrics = fixture.0.metricsSnapshot
        #expect(metrics.cyclesExecuted == 2)
        #expect(metrics.lastCycleAt == clock.now)
        #expect(metrics.lastCycleDuration == 2)
        #expect(metrics.lastSuccessfulPersistenceAt == clock.now)
        #expect(metrics.lastMaintenanceAt != nil)
    }

    @Test("Single-instance lock rejects a second owner and can be reused")
    func testSingleInstanceLock() throws {
        let directory = NSTemporaryDirectory() + "runtime-lock-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/monitor.lock"

        let first = try SingleInstanceLock(path: path)
        #expect(throws: SingleInstanceLockError.self) {
            _ = try SingleInstanceLock(path: path)
        }
        first.release()
        let second = try SingleInstanceLock(path: path)
        second.release()
    }
}

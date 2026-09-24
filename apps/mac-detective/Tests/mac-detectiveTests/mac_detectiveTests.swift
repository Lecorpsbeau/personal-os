import Foundation
import Testing
@testable import mac_detective

@Suite("FSUsageParser Tests")
struct FSUsageParserTests {

    let parser = FSUsageParser()

    @Test("Valid sample from fs_usage diskio")
    func testValidSample() throws {
        let sample = "21:55:20.636784    PgOut[AP]    D=0x0194580d  B=0x7000   /dev/disk3s6   0.000026 W kernel_task.117"

        let event = try #require(parser.parse(sample))
        #expect(event.processName == "kernel_task")
        #expect(event.pid == 117)
        #expect(event.operation == "W")
        #expect(event.bytes == 28672)

        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.hour, .minute, .second], from: event.timestamp)
        #expect(components.hour == 21)
        #expect(components.minute == 55)
        #expect(components.second == 20)
    }

    @Test("Leading and trailing whitespace and multiline strings")
    func testWhitespaceHandling() throws {
        let multilineSample = """
        21:55:20.636784    PgOut[AP]    D=0x0194580d  B=0x7000   /dev/disk3s6   0.000026 W kernel_task.117
        """

        let event1 = try #require(parser.parse(multilineSample))
        #expect(event1.processName == "kernel_task")
        #expect(event1.pid == 117)
        #expect(event1.operation == "W")
        #expect(event1.bytes == 28672)

        let paddedSample = "\n\t  21:55:20.636784    PgOut[AP]    D=0x0194580d  B=0x7000   /dev/disk3s6   0.000026 W kernel_task.117  \r\n  "
        let event2 = try #require(parser.parse(paddedSample))
        #expect(event2.processName == "kernel_task")
        #expect(event2.pid == 117)
        #expect(event2.operation == "W")
        #expect(event2.bytes == 28672)
    }

    @Test("Various valid operations and process naming conventions")
    func testValidVariations() throws {
        // Read operation with single-digit PID
        let readSample = "10:15:30.123456    Read    D=0x01000000  B=0x1000   /dev/disk1s1   0.000100 R launchd.1"
        let event1 = try #require(parser.parse(readSample))
        #expect(event1.processName == "launchd")
        #expect(event1.pid == 1)
        #expect(event1.operation == "R")
        #expect(event1.bytes == 4096)

        // Process name containing dots
        let dottedProcSample = "12:00:00.000001    Write    D=0x02000000  B=0x2000   /dev/disk3s1   0.000050 W com.apple.WebKit.WebContent.5678"
        let event2 = try #require(parser.parse(dottedProcSample))
        #expect(event2.processName == "com.apple.WebKit.WebContent")
        #expect(event2.pid == 5678)
        #expect(event2.operation == "W")
        #expect(event2.bytes == 8192)

        // Process name containing spaces
        let spacedProcSample = "14:20:10.500000    Write    D=0x03000000  B=0x800   /dev/disk3s1   0.000020 W Google Chrome.1234"
        let event3 = try #require(parser.parse(spacedProcSample))
        #expect(event3.processName == "Google Chrome")
        #expect(event3.pid == 1234)
        #expect(event3.operation == "W")
        #expect(event3.bytes == 2048)
    }

    @Test("Malformed inputs safely return nil without crashing")
    func testMalformedInputs() {
        let malformedInputs = [
            "",
            "   \n\t  ",
            "just random garbage text",
            "21:55:20.636784",
            // Multiple non-empty lines in one call
            "21:55:20.636784    PgOut[AP]    D=0x0194580d  B=0x7000   /dev/disk3s6   0.000026 W kernel_task.117\n21:55:20.636784    PgOut[AP]    D=0x0194580d  B=0x7000   /dev/disk3s6   0.000026 W kernel_task.117",
            // Invalid timestamp
            "99:99:99.999999    PgOut[AP]    D=0x0194580d  B=0x7000   /dev/disk3s6   0.000026 W kernel_task.117",
            "not_a_time    PgOut[AP]    D=0x0194580d  B=0x7000   /dev/disk3s6   0.000026 W kernel_task.117",
            // Missing B=0x byte count
            "21:55:20.636784    PgOut[AP]    D=0x0194580d  /dev/disk3s6   0.000026 W kernel_task.117",
            // Invalid hex byte count
            "21:55:20.636784    PgOut[AP]    D=0x0194580d  B=0xZZZZ   /dev/disk3s6   0.000026 W kernel_task.117",
            "21:55:20.636784    PgOut[AP]    D=0x0194580d  B=0x   /dev/disk3s6   0.000026 W kernel_task.117",
            // Missing PID
            "21:55:20.636784    PgOut[AP]    D=0x0194580d  B=0x7000   /dev/disk3s6   0.000026 W kernel_task",
            // Non-numeric PID
            "21:55:20.636784    PgOut[AP]    D=0x0194580d  B=0x7000   /dev/disk3s6   0.000026 W kernel_task.abc",
            // Negative PID
            "21:55:20.636784    PgOut[AP]    D=0x0194580d  B=0x7000   /dev/disk3s6   0.000026 W kernel_task.-5",
            // Empty process name
            "21:55:20.636784    PgOut[AP]    D=0x0194580d  B=0x7000   /dev/disk3s6   0.000026 W .117",
            // Missing operation
            "21:55:20.636784    PgOut[AP]    D=0x0194580d  B=0x7000   /dev/disk3s6   0.000026 kernel_task.117"
        ]

        for input in malformedInputs {
            let result = parser.parse(input)
            #expect(result == nil, "Expected nil for input: \(input)")
        }
    }
}

@Suite("FSUsageCollector Integration Tests")
struct FSUsageCollectorIntegrationTests {

    @Test("Process raw output and drain events")
    func testProcessOutputAndDrain() {
        let collector = FSUsageCollector()

        let rawOutput = """
        21:55:20.636784    PgOut[AP]    D=0x0194580d  B=0x7000   /dev/disk3s6   0.000026 W kernel_task.117
        21:55:21.100000    Read         D=0x01000000  B=0x1000   /dev/disk1s1   0.000050 R launchd.1
        """

        collector.processOutput(rawOutput)

        let events = collector.drainEvents()
        #expect(events.count == 2)
        #expect(events[0].processName == "kernel_task")
        #expect(events[0].pid == 117)
        #expect(events[0].operation == "W")
        #expect(events[0].bytes == 28672)

        #expect(events[1].processName == "launchd")
        #expect(events[1].pid == 1)
        #expect(events[1].operation == "R")
        #expect(events[1].bytes == 4096)

        // Draining again should be empty
        let drainedAgain = collector.drainEvents()
        #expect(drainedAgain.isEmpty)
    }

    @Test("onEvent callback receives parsed events in real time")
    func testOnEventCallback() {
        final class EventBox: @unchecked Sendable {
            private let lock = NSLock()
            private var _events: [DiskProcessEvent] = []
            var events: [DiskProcessEvent] {
                lock.lock()
                defer { lock.unlock() }
                return _events
            }
            func append(_ event: DiskProcessEvent) {
                lock.lock()
                defer { lock.unlock() }
                _events.append(event)
            }
        }

        let collector = FSUsageCollector()
        let box = EventBox()

        collector.onEvent = { event in
            box.append(event)
        }

        let rawOutput = """
        21:55:20.636784    PgOut[AP]    D=0x0194580d  B=0x7000   /dev/disk3s6   0.000026 W kernel_task.117
        invalid line that should be skipped
        21:55:22.000000    Write        D=0x02000000  B=0x2000   /dev/disk3s1   0.000010 W mds.54
        """

        collector.processOutput(rawOutput)

        #expect(box.events.count == 2)
        #expect(box.events[0].processName == "kernel_task")
        #expect(box.events[1].processName == "mds")
        #expect(box.events[1].pid == 54)
    }

    @Test("Buffer capacity limit drops older events when exceeded")
    func testBufferLimit() {
        let collector = FSUsageCollector(maxBufferSize: 2)

        let rawOutput = """
        21:55:20.000001    Write    D=0x1  B=0x100   /dev/disk1   0.000010 W procA.10
        21:55:20.000002    Write    D=0x2  B=0x200   /dev/disk1   0.000020 W procB.20
        21:55:20.000003    Write    D=0x3  B=0x300   /dev/disk1   0.000030 W procC.30
        """

        collector.processOutput(rawOutput)

        let events = collector.drainEvents()
        #expect(events.count == 2)
        #expect(events[0].processName == "procB")
        #expect(events[1].processName == "procC")
    }

    @Test("Malformed lines are safely ignored without generating events")
    func testMalformedLinesIgnored() {
        let collector = FSUsageCollector()

        let rawOutput = """
        sudo: a password is required
        fs_usage: invalid argument
        random garbage
        """

        collector.processOutput(rawOutput)
        #expect(collector.drainEvents().isEmpty)
    }
}

@Suite("Database DiskProcessEvents Tests")
struct DatabaseDiskProcessEventsTests {

    private func makeTemporaryDatabase() -> (Database, String) {
        let tempPath = NSTemporaryDirectory() + "test_db_\(UUID().uuidString).sqlite"
        let db = Database(databasePath: tempPath)
        return (db, tempPath)
    }

    private func cleanDatabase(path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test("Insert single DiskProcessEvent and verify all fields")
    func testSingleDiskProcessEventPersistence() throws {
        let (db, path) = makeTemporaryDatabase()
        defer { cleanDatabase(path: path) }

        let timestamp = Date(timeIntervalSince1970: 1700000000.5)
        let event = DiskProcessEvent(
            timestamp: timestamp,
            operation: "W",
            bytes: 28672,
            processName: "kernel_task",
            pid: 117
        )

        let success = db.saveDiskProcessEvent(event)
        #expect(success)

        let events = db.getDiskProcessEvents()
        #expect(events.count == 1)

        let retrieved = try #require(events.first)
        #expect(retrieved.processName == "kernel_task")
        #expect(retrieved.pid == 117)
        #expect(retrieved.operation == "W")
        #expect(retrieved.bytes == 28672)
        #expect(abs(retrieved.timestamp.timeIntervalSince(timestamp)) < 0.001)
    }

    @Test("Insert multiple DiskProcessEvents in batch")
    func testMultipleDiskProcessEvents() {
        let (db, path) = makeTemporaryDatabase()
        defer { cleanDatabase(path: path) }

        let events = [
            DiskProcessEvent(timestamp: Date(), operation: "R", bytes: 4096, processName: "launchd", pid: 1),
            DiskProcessEvent(timestamp: Date(), operation: "W", bytes: 8192, processName: "mds", pid: 54),
            DiskProcessEvent(timestamp: Date(), operation: "W", bytes: 2048, processName: "Google Chrome", pid: 1234)
        ]

        let insertedCount = db.saveDiskProcessEvents(events)
        #expect(insertedCount == 3)

        let retrieved = db.getDiskProcessEvents()
        #expect(retrieved.count == 3)
        #expect(retrieved[0].processName == "launchd")
        #expect(retrieved[1].processName == "mds")
        #expect(retrieved[2].processName == "Google Chrome")
    }

    @Test("Empty event batch is handled safely")
    func testEmptyBatchSafe() {
        let (db, path) = makeTemporaryDatabase()
        defer { cleanDatabase(path: path) }

        let inserted = db.saveDiskProcessEvents([])
        #expect(inserted == 0)

        let retrieved = db.getDiskProcessEvents()
        #expect(retrieved.isEmpty)
    }

    @Test("Events can be linked to snapshotID and filtered")
    func testSnapshotIDLinking() throws {
        let (db, path) = makeTemporaryDatabase()
        defer { cleanDatabase(path: path) }

        let snapshot = SystemSnapshot(
            timestamp: Date(),
            cpu: 10.0,
            memory: 50.0,
            diskRead: 1000.0,
            diskWrite: 2000.0,
            networkIn: 500.0,
            networkOut: 600.0,
            processes: []
        )

        let snapshotID = try #require(db.save(snapshot: snapshot))

        let linkedEvent = DiskProcessEvent(timestamp: Date(), operation: "W", bytes: 1024, processName: "proc1", pid: 100)
        let unlinkedEvent = DiskProcessEvent(timestamp: Date(), operation: "R", bytes: 2048, processName: "proc2", pid: 200)

        db.saveDiskProcessEvent(linkedEvent, snapshotID: snapshotID)
        db.saveDiskProcessEvent(unlinkedEvent, snapshotID: nil)

        let linkedOnly = db.getDiskProcessEvents(snapshotID: snapshotID)
        #expect(linkedOnly.count == 1)
        #expect(linkedOnly.first?.processName == "proc1")

        let allEvents = db.getDiskProcessEvents()
        #expect(allEvents.count == 2)
    }

    @Test("Existing database functionality remains intact")
    func testExistingDatabaseOperations() throws {
        let (db, path) = makeTemporaryDatabase()
        defer { cleanDatabase(path: path) }

        let proc = ProcessSnapshot(
            pid: 42,
            name: "test_process",
            cpuUsage: 12.5,
            memoryBytes: 1048576,
            diskReadBytes: 0,
            diskWriteBytes: 0
        )

        let snapshot = SystemSnapshot(
            timestamp: Date(),
            cpu: 5.0,
            memory: 40.0,
            diskRead: 100.0,
            diskWrite: 200.0,
            networkIn: 300.0,
            networkOut: 400.0,
            processes: [proc]
        )

        let snapshotID = try #require(db.save(snapshot: snapshot))
        #expect(snapshotID > 0)

        let top = db.getTopProcesses(snapshotID: snapshotID, limit: 1)
        #expect(top.count == 1)
        #expect(top.first?.name == "test_process")
        #expect(top.first?.pid == 42)

        let detected = DetectedEvent(
            type: "CPU_SPIKE",
            severity: "HIGH",
            value: 99.0,
            message: "CPU is high"
        )
        db.saveEvent(detected, snapshotID: snapshotID, timestamp: snapshot.timestamp)
    }
}

@Suite("Disk Activity Ranking Tests")
struct DiskActivityRankingTests {

    private func makeTemporaryDatabase() -> (Database, String) {
        let tempPath = NSTemporaryDirectory() + "test_ranking_\(UUID().uuidString).sqlite"
        let db = Database(databasePath: tempPath)
        return (db, tempPath)
    }

    private func cleanDatabase(path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test("Empty table returns empty ranking")
    func testEmptyRanking() {
        let (db, path) = makeTemporaryDatabase()
        defer { cleanDatabase(path: path) }

        let results = db.getTopDiskProcesses()
        #expect(results.isEmpty)
    }

    @Test("Multiple events from same process are aggregated")
    func testSameProcessAggregation() {
        let (db, path) = makeTemporaryDatabase()
        defer { cleanDatabase(path: path) }

        let events = [
            DiskProcessEvent(timestamp: Date(), operation: "R", bytes: 4096,  processName: "chrome", pid: 100),
            DiskProcessEvent(timestamp: Date(), operation: "R", bytes: 8192,  processName: "chrome", pid: 100),
            DiskProcessEvent(timestamp: Date(), operation: "W", bytes: 2048,  processName: "chrome", pid: 100),
        ]
        db.saveDiskProcessEvents(events)

        let results = db.getTopDiskProcesses()
        #expect(results.count == 1)

        let summary = results[0]
        #expect(summary.processName == "chrome")
        #expect(summary.pid == 100)
        #expect(summary.readBytes  == 12288)   // 4096 + 8192
        #expect(summary.writeBytes == 2048)
        #expect(summary.totalBytes == 14336)   // 12288 + 2048
    }

    @Test("Read bytes are summed correctly across events")
    func testReadBytesSum() {
        let (db, path) = makeTemporaryDatabase()
        defer { cleanDatabase(path: path) }

        db.saveDiskProcessEvents([
            DiskProcessEvent(timestamp: Date(), operation: "R", bytes: 1000, processName: "proc", pid: 1),
            DiskProcessEvent(timestamp: Date(), operation: "R", bytes: 2000, processName: "proc", pid: 1),
            DiskProcessEvent(timestamp: Date(), operation: "R", bytes: 3000, processName: "proc", pid: 1),
        ])

        let results = db.getTopDiskProcesses()
        #expect(results.first?.readBytes == 6000)
        #expect(results.first?.writeBytes == 0)
        #expect(results.first?.totalBytes == 6000)
    }

    @Test("Write bytes are summed correctly across events")
    func testWriteBytesSum() {
        let (db, path) = makeTemporaryDatabase()
        defer { cleanDatabase(path: path) }

        db.saveDiskProcessEvents([
            DiskProcessEvent(timestamp: Date(), operation: "W", bytes: 512,  processName: "proc", pid: 1),
            DiskProcessEvent(timestamp: Date(), operation: "W", bytes: 1024, processName: "proc", pid: 1),
        ])

        let results = db.getTopDiskProcesses()
        #expect(results.first?.readBytes  == 0)
        #expect(results.first?.writeBytes == 1536)
        #expect(results.first?.totalBytes == 1536)
    }

    @Test("Multi-word operation prefixed with R is counted as read")
    func testOperationPrefixMatching() {
        let (db, path) = makeTemporaryDatabase()
        defer { cleanDatabase(path: path) }

        // Operations from fs_usage can be: R, W, Read, Write, RdMeta, WrMeta, PgIn, PgOut, etc.
        // UPPER(operation) LIKE 'R%' covers R, Read, RdMeta
        // UPPER(operation) LIKE 'W%' covers W, Write, WrMeta
        db.saveDiskProcessEvents([
            DiskProcessEvent(timestamp: Date(), operation: "Read",   bytes: 4096, processName: "mds", pid: 10),
            DiskProcessEvent(timestamp: Date(), operation: "Write",  bytes: 2048, processName: "mds", pid: 10),
            DiskProcessEvent(timestamp: Date(), operation: "RdMeta", bytes: 512,  processName: "mds", pid: 10),
            DiskProcessEvent(timestamp: Date(), operation: "WrMeta", bytes: 256,  processName: "mds", pid: 10),
            // PgOut starts with neither R nor W — treated as neither read nor write
            DiskProcessEvent(timestamp: Date(), operation: "PgOut",  bytes: 1024, processName: "mds", pid: 10),
        ])

        let results = db.getTopDiskProcesses()
        #expect(results.count == 1)

        let s = results[0]
        #expect(s.readBytes  == 4608)   // Read + RdMeta = 4096 + 512
        #expect(s.writeBytes == 2304)   // Write + WrMeta = 2048 + 256
        #expect(s.totalBytes == 7936)   // all five events summed
    }

    @Test("Processes are ranked by total bytes descending")
    func testRankingOrder() {
        let (db, path) = makeTemporaryDatabase()
        defer { cleanDatabase(path: path) }

        db.saveDiskProcessEvents([
            DiskProcessEvent(timestamp: Date(), operation: "R", bytes: 100,   processName: "small",  pid: 1),
            DiskProcessEvent(timestamp: Date(), operation: "W", bytes: 50000, processName: "large",  pid: 2),
            DiskProcessEvent(timestamp: Date(), operation: "R", bytes: 5000,  processName: "medium", pid: 3),
        ])

        let results = db.getTopDiskProcesses()
        #expect(results.count == 3)
        #expect(results[0].processName == "large")
        #expect(results[1].processName == "medium")
        #expect(results[2].processName == "small")
    }

    @Test("limit parameter caps the number of results")
    func testLimitParameter() {
        let (db, path) = makeTemporaryDatabase()
        defer { cleanDatabase(path: path) }

        db.saveDiskProcessEvents([
            DiskProcessEvent(timestamp: Date(), operation: "R", bytes: 9000, processName: "a", pid: 1),
            DiskProcessEvent(timestamp: Date(), operation: "R", bytes: 8000, processName: "b", pid: 2),
            DiskProcessEvent(timestamp: Date(), operation: "R", bytes: 7000, processName: "c", pid: 3),
            DiskProcessEvent(timestamp: Date(), operation: "R", bytes: 6000, processName: "d", pid: 4),
        ])

        let top2 = db.getTopDiskProcesses(limit: 2)
        #expect(top2.count == 2)
        #expect(top2[0].processName == "a")
        #expect(top2[1].processName == "b")
    }

    @Test("snapshotID filtering returns only events for that snapshot")
    func testSnapshotIDFiltering() throws {
        let (db, path) = makeTemporaryDatabase()
        defer { cleanDatabase(path: path) }

        let snapshot = SystemSnapshot(
            timestamp: Date(), cpu: 1, memory: 1,
            diskRead: 1, diskWrite: 1, networkIn: 1, networkOut: 1, processes: []
        )
        let snapshotID = try #require(db.save(snapshot: snapshot))

        // Linked to snapshot
        db.saveDiskProcessEvents([
            DiskProcessEvent(timestamp: Date(), operation: "R", bytes: 5000, processName: "snap_proc", pid: 10),
            DiskProcessEvent(timestamp: Date(), operation: "W", bytes: 3000, processName: "snap_proc", pid: 10),
        ], snapshotID: snapshotID)

        // Unlinked (snapshot_id NULL)
        db.saveDiskProcessEvents([
            DiskProcessEvent(timestamp: Date(), operation: "R", bytes: 99999, processName: "other_proc", pid: 99),
        ])

        let filtered = db.getTopDiskProcesses(snapshotID: snapshotID)
        #expect(filtered.count == 1)
        #expect(filtered[0].processName == "snap_proc")
        #expect(filtered[0].readBytes   == 5000)
        #expect(filtered[0].writeBytes  == 3000)
        #expect(filtered[0].totalBytes  == 8000)

        // Global query sees both
        let all = db.getTopDiskProcesses()
        #expect(all.count == 2)
        // other_proc has more total bytes so it ranks first
        #expect(all[0].processName == "other_proc")
    }

    @Test("Total bytes equals sum of read and write bytes")
    func testTotalBytesInvariant() {
        let (db, path) = makeTemporaryDatabase()
        defer { cleanDatabase(path: path) }

        db.saveDiskProcessEvents([
            DiskProcessEvent(timestamp: Date(), operation: "R", bytes: 1111, processName: "p", pid: 1),
            DiskProcessEvent(timestamp: Date(), operation: "W", bytes: 2222, processName: "p", pid: 1),
            // PgOut is neither R nor W, still counts in total
            DiskProcessEvent(timestamp: Date(), operation: "PgOut", bytes: 333, processName: "p", pid: 1),
        ])

        let results = db.getTopDiskProcesses()
        let s = results[0]
        #expect(s.readBytes  == 1111)
        #expect(s.writeBytes == 2222)
        #expect(s.totalBytes == 3666)   // ALL bytes, not just read+write
        // Note: totalBytes = SUM(all bytes), readBytes+writeBytes may be < totalBytes
        // when operations are neither R* nor W* (e.g. PgOut)
    }
}

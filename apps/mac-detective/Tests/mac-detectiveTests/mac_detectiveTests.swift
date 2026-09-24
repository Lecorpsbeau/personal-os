import CProcessRusage
import Darwin
import Foundation
import SQLite3
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

    private func makeReferenceDate(
        year: Int = 2026,
        month: Int = 9,
        day: Int = 24,
        hour: Int = 12,
        minute: Int = 0,
        second: Int = 0
    ) -> (Date, Calendar) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let date = calendar.date(
            from: DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute,
                second: second
            )
        )!
        return (date, calendar)
    }

    @Test("Timestamp uses the injected reference date")
    func testTimestampUsesReferenceDate() throws {
        let (referenceDate, calendar) = makeReferenceDate(
            year: 2026,
            month: 9,
            day: 24,
            hour: 23,
            minute: 59,
            second: 58
        )
        let parser = FSUsageParser(
            referenceDate: referenceDate,
            calendar: calendar
        )
        let sample = "00:00:00.000001    Read    D=0x1  B=0x100   /dev/disk1   0.000001 R procA.10"

        let event = try #require(parser.parse(sample))
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: event.timestamp
        )

        #expect(components.year == 2026)
        #expect(components.month == 9)
        #expect(components.day == 24)
        #expect(components.hour == 0)
        #expect(components.minute == 0)
        #expect(components.second == 0)
        #expect(abs((components.nanosecond ?? 0) - 1_000) <= 1_000)
    }

    @Test("Fractional seconds are preserved")
    func testFractionalSecondsArePreserved() throws {
        let (referenceDate, calendar) = makeReferenceDate()
        let parser = FSUsageParser(
            referenceDate: referenceDate,
            calendar: calendar
        )
        let sample = "14:32:10.123456789    Write    D=0x1  B=0x200   /dev/disk1   0.000001 W procB.20"

        let event = try #require(parser.parse(sample))
        let components = calendar.dateComponents(
            [.hour, .minute, .second, .nanosecond],
            from: event.timestamp
        )

        #expect(components.hour == 14)
        #expect(components.minute == 32)
        #expect(components.second == 10)
        #expect(abs((components.nanosecond ?? 0) - 123_456_789) <= 1_000)
    }

    @Test("Invalid fractions are rejected")
    func testInvalidFractionIsRejected() {
        let (referenceDate, calendar) = makeReferenceDate()
        let parser = FSUsageParser(
            referenceDate: referenceDate,
            calendar: calendar
        )
        let sample = "14:32:10.1234567890    Write    D=0x1  B=0x200   /dev/disk1   0.000001 W procB.20"

        #expect(parser.parse(sample) == nil)
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

    @Test("Buffered events remain available until explicitly acknowledged")
    func testBufferedEventsRequireAcknowledgement() {
        let collector = FSUsageCollector()
        let rawOutput = """
        21:55:20.000001    Write    D=0x1  B=0x100   /dev/disk1   0.000010 W procA.10
        21:55:20.000002    Read     D=0x2  B=0x200   /dev/disk1   0.000020 R procB.20
        """

        collector.processOutput(rawOutput)

        let buffered = collector.getBufferedEvents()
        #expect(buffered.count == 2)
        #expect(collector.getBufferedEvents() == buffered)

        collector.acknowledgeBufferedEvents(count: 1)
        #expect(collector.getBufferedEvents().map(\.processName) == ["procB"])

        collector.acknowledgeBufferedEvents(count: 10)
        #expect(collector.getBufferedEvents().isEmpty)
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

@Suite("SQLite Event Text Integrity Tests")
struct SQLiteEventTextIntegrityTests {

    private struct StoredEvent: Equatable {
        let type: String
        let severity: String
        let message: String
    }

    private func makeTemporaryDatabase() -> (Database, String) {
        let tempPath = NSTemporaryDirectory() + "test_event_text_\(UUID().uuidString).sqlite"
        let database = Database(databasePath: tempPath)
        return (database, tempPath)
    }

    private func cleanDatabase(path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func readEvents(databasePath: String) throws -> [StoredEvent] {
        var connection: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databasePath,
            &connection,
            SQLITE_OPEN_READONLY,
            nil
        )
        try #require(openResult == SQLITE_OK)

        defer {
            sqlite3_close(connection)
        }

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(
            connection,
            "SELECT type, severity, message FROM events ORDER BY id ASC;",
            -1,
            &statement,
            nil
        )
        try #require(prepareResult == SQLITE_OK)
        defer {
            sqlite3_finalize(statement)
        }

        var events: [StoredEvent] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            let typePointer = try #require(sqlite3_column_text(statement, 0))
            let severityPointer = try #require(sqlite3_column_text(statement, 1))
            let messagePointer = try #require(sqlite3_column_text(statement, 2))

            events.append(
                StoredEvent(
                    type: String(cString: typePointer),
                    severity: String(cString: severityPointer),
                    message: String(cString: messagePointer)
                )
            )
        }

        return events
    }

    @Test("Event text fields survive an actual SQLite round-trip")
    func testEventTextRoundTrip() throws {
        let (database, path) = makeTemporaryDatabase()
        defer { cleanDatabase(path: path) }

        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = SystemSnapshot(
            timestamp: timestamp,
            cpu: 10,
            memory: 50,
            diskRead: 100,
            diskWrite: 200,
            networkIn: 300,
            networkOut: 400,
            processes: []
        )
        let snapshotID = try #require(database.save(snapshot: snapshot))

        let expected = [
            StoredEvent(
                type: "CPU_SPIKE",
                severity: "high",
                message: "CPU usage above 80%"
            ),
            StoredEvent(
                type: "DISK_ÉVÉNEMENT_✅",
                severity: "critique_élevée",
                message: "Écriture spéciale: café / naïve / 北京"
            ),
            StoredEvent(
                type: "TYPE !@#$%^&*()",
                severity: "medium+accent-é",
                message: "Quote: \" apostrophe: ' slash: \\ newline:\n tab:\t <tag>&"
            )
        ]

        for (index, event) in expected.enumerated() {
            database.saveEvent(
                DetectedEvent(
                    type: event.type,
                    severity: event.severity,
                    value: Double(index),
                    message: event.message
                ),
                snapshotID: snapshotID,
                timestamp: timestamp
            )
        }

        let stored = try readEvents(databasePath: path)
        #expect(stored == expected)
    }
}

@Suite("SQLite Migration Tests")
struct SQLiteMigrationTests {

    private func makeTemporaryPath() -> String {
        NSTemporaryDirectory() + "test_migration_\(UUID().uuidString).sqlite"
    }

    private func cleanDatabase(path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    private func execute(_ sql: String, databasePath: String) throws {
        var connection: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databasePath,
            &connection,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        )
        try #require(openResult == SQLITE_OK)

        defer {
            sqlite3_close(connection)
        }

        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(
            connection,
            sql,
            nil,
            nil,
            &errorMessage
        )

        if result != SQLITE_OK {
            let message = errorMessage.map {
                String(cString: $0)
            } ?? "unknown SQLite error"
            sqlite3_free(errorMessage)
            throw MigrationTestError.sqlite(message)
        }
    }

    private func readInteger(
        _ sql: String,
        databasePath: String
    ) throws -> Int32 {
        var connection: OpaquePointer?
        try #require(
            sqlite3_open_v2(
                databasePath,
                &connection,
                SQLITE_OPEN_READONLY,
                nil
            ) == SQLITE_OK
        )
        defer {
            sqlite3_close(connection)
        }

        var statement: OpaquePointer?
        try #require(
            sqlite3_prepare_v2(
                connection,
                sql,
                -1,
                &statement,
                nil
            ) == SQLITE_OK
        )
        defer {
            sqlite3_finalize(statement)
        }

        try #require(sqlite3_step(statement) == SQLITE_ROW)
        return sqlite3_column_int(statement, 0)
    }

    private func objectExists(
        type: String,
        name: String,
        databasePath: String
    ) throws -> Bool {
        var connection: OpaquePointer?
        try #require(
            sqlite3_open_v2(
                databasePath,
                &connection,
                SQLITE_OPEN_READONLY,
                nil
            ) == SQLITE_OK
        )
        defer {
            sqlite3_close(connection)
        }

        var statement: OpaquePointer?
        try #require(
            sqlite3_prepare_v2(
                connection,
                "SELECT COUNT(*) FROM sqlite_master WHERE type = ? AND name = ?;",
                -1,
                &statement,
                nil
            ) == SQLITE_OK
        )
        defer {
            sqlite3_finalize(statement)
        }

        _ = sqlite3_bind_text(statement, 1, type, -1, sqliteTransientForTests)
        _ = sqlite3_bind_text(statement, 2, name, -1, sqliteTransientForTests)
        try #require(sqlite3_step(statement) == SQLITE_ROW)
        return sqlite3_column_int(statement, 0) == 1
    }

    private func columnExists(
        _ column: String,
        databasePath: String
    ) throws -> Bool {
        var connection: OpaquePointer?
        try #require(
            sqlite3_open_v2(
                databasePath,
                &connection,
                SQLITE_OPEN_READONLY,
                nil
            ) == SQLITE_OK
        )
        defer {
            sqlite3_close(connection)
        }

        var statement: OpaquePointer?
        try #require(
            sqlite3_prepare_v2(
                connection,
                "PRAGMA table_info(process_samples);",
                -1,
                &statement,
                nil
            ) == SQLITE_OK
        )
        defer {
            sqlite3_finalize(statement)
        }

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let namePointer = sqlite3_column_text(statement, 1) else {
                continue
            }

            if String(cString: namePointer) == column {
                return true
            }
        }

        return false
    }

    private func createInitialSchema(databasePath: String) throws {
        try execute(
            """
            CREATE TABLE system_samples (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp REAL NOT NULL,
                cpu REAL NOT NULL,
                memory REAL NOT NULL,
                disk_read REAL NOT NULL,
                disk_write REAL NOT NULL,
                network_in REAL NOT NULL,
                network_out REAL NOT NULL
            );

            CREATE TABLE process_samples (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                snapshot_id INTEGER NOT NULL,
                timestamp REAL NOT NULL,
                pid INTEGER NOT NULL,
                name TEXT NOT NULL,
                cpu REAL NOT NULL,
                memory INTEGER NOT NULL,
                FOREIGN KEY(snapshot_id) REFERENCES system_samples(id)
            );

            CREATE TABLE events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                snapshot_id INTEGER NOT NULL,
                timestamp REAL NOT NULL,
                type TEXT NOT NULL,
                severity TEXT NOT NULL,
                value REAL NOT NULL,
                message TEXT NOT NULL,
                FOREIGN KEY(snapshot_id) REFERENCES system_samples(id)
            );

            INSERT INTO system_samples (
                id, timestamp, cpu, memory, disk_read, disk_write,
                network_in, network_out
            ) VALUES (
                1, 1700000000, 12.5, 50.0, 100.0, 200.0, 300.0, 400.0
            );

            INSERT INTO process_samples (
                id, snapshot_id, timestamp, pid, name, cpu, memory
            ) VALUES (
                1, 1, 1700000000, 42, 'legacy_process', 3.5, 4096
            );

            INSERT INTO events (
                id, snapshot_id, timestamp, type, severity, value, message
            ) VALUES (
                1, 1, 1700000000, 'LEGACY_EVENT', 'legacy', 1.0, 'preserved'
            );
            """,
            databasePath: databasePath
        )
    }

    private func emptySnapshot() -> SystemSnapshot {
        SystemSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            cpu: 1,
            memory: 2,
            diskRead: 3,
            diskWrite: 4,
            networkIn: 5,
            networkOut: 6,
            processes: []
        )
    }

    @Test("Empty database migrates to the current schema")
    func testEmptyDatabaseMigration() throws {
        let path = makeTemporaryPath()
        defer { cleanDatabase(path: path) }

        let database = Database(databasePath: path)

        #expect(try readInteger("PRAGMA user_version;", databasePath: path) == 4)
        #expect(try objectExists(type: "table", name: "system_samples", databasePath: path))
        #expect(try objectExists(type: "table", name: "process_samples", databasePath: path))
        #expect(try objectExists(type: "table", name: "events", databasePath: path))
        #expect(try objectExists(type: "table", name: "disk_process_events", databasePath: path))
        #expect(try columnExists("disk_read_bytes", databasePath: path))
        #expect(try columnExists("disk_write_bytes", databasePath: path))
        #expect(try objectExists(type: "index", name: "idx_disk_process_events_snapshot_id", databasePath: path))
        #expect(try objectExists(type: "index", name: "idx_process_samples_snapshot_cpu", databasePath: path))
        #expect(database.getDiskProcessEvents().isEmpty)
    }

    @Test("Initial schema migrates without losing existing rows")
    func testInitialSchemaMigrationPreservesData() throws {
        let path = makeTemporaryPath()
        defer { cleanDatabase(path: path) }

        try createInitialSchema(databasePath: path)
        let database = Database(databasePath: path)

        #expect(try readInteger("PRAGMA user_version;", databasePath: path) == 4)
        #expect(try readInteger("SELECT COUNT(*) FROM system_samples;", databasePath: path) == 1)
        #expect(try readInteger("SELECT COUNT(*) FROM process_samples;", databasePath: path) == 1)
        #expect(try readInteger("SELECT COUNT(*) FROM events;", databasePath: path) == 1)
        #expect(try readInteger("SELECT disk_read_bytes FROM process_samples WHERE id = 1;", databasePath: path) == 0)
        #expect(try readInteger("SELECT disk_write_bytes FROM process_samples WHERE id = 1;", databasePath: path) == 0)
        #expect(try readInteger("SELECT pid FROM process_samples WHERE id = 1;", databasePath: path) == 42)
        #expect(database.getTopProcesses(snapshotID: 1, limit: 1).first?.name == "legacy_process")
    }

    @Test("Current schema is accepted without structural changes")
    func testCurrentSchemaIsAccepted() throws {
        let path = makeTemporaryPath()
        defer { cleanDatabase(path: path) }

        do {
            let database = Database(databasePath: path)
            #expect(database.save(snapshot: emptySnapshot()) != nil)
        }

        let reopened = Database(databasePath: path)

        #expect(try readInteger("PRAGMA user_version;", databasePath: path) == 4)
        #expect(try readInteger("SELECT COUNT(*) FROM system_samples;", databasePath: path) == 1)
        #expect(try columnExists("disk_read_bytes", databasePath: path))
        #expect(try objectExists(type: "table", name: "disk_process_events", databasePath: path))
        #expect(reopened.getDiskProcessEvents().isEmpty)
    }

    @Test("Repeated initialization is idempotent")
    func testRepeatedMigrationIsIdempotent() throws {
        let path = makeTemporaryPath()
        defer { cleanDatabase(path: path) }

        do {
            let database = Database(databasePath: path)
            #expect(database.save(snapshot: emptySnapshot()) != nil)
        }

        for _ in 0..<3 {
            let database = Database(databasePath: path)
            #expect(database.getTopDiskProcesses().isEmpty)
        }

        #expect(try readInteger("PRAGMA user_version;", databasePath: path) == 4)
        #expect(try readInteger("SELECT COUNT(*) FROM system_samples;", databasePath: path) == 1)
        #expect(try columnExists("disk_read_bytes", databasePath: path))
        #expect(try columnExists("disk_write_bytes", databasePath: path))
    }

    @Test("Failed migration rolls back all schema changes")
    func testFailedMigrationRollsBack() throws {
        let path = makeTemporaryPath()
        defer { cleanDatabase(path: path) }

        try createInitialSchema(databasePath: path)
        try execute(
            "CREATE VIEW disk_process_events AS SELECT 1 AS marker;",
            databasePath: path
        )

        let database = Database(databasePath: path)

        #expect(try readInteger("PRAGMA user_version;", databasePath: path) == 0)
        #expect(!(try columnExists("disk_read_bytes", databasePath: path)))
        #expect(!(try columnExists("disk_write_bytes", databasePath: path)))
        #expect(try readInteger("SELECT COUNT(*) FROM system_samples;", databasePath: path) == 1)
        #expect(database.getDiskProcessEvents().isEmpty)
    }

    @Test("Foreign keys are enforced on the Database connection")
    func testForeignKeysAreEnabled() throws {
        let path = makeTemporaryPath()
        defer { cleanDatabase(path: path) }

        let database = Database(databasePath: path)
        let orphanEvent = DiskProcessEvent(
            timestamp: Date(),
            operation: "W",
            bytes: 1024,
            processName: "orphan",
            pid: 999
        )

        #expect(!database.saveDiskProcessEvent(orphanEvent, snapshotID: 999_999))
        #expect(database.getDiskProcessEvents().isEmpty)
    }
}

@Suite("Atomic Snapshot Persistence Tests")
struct AtomicSnapshotPersistenceTests {

    private func makeTemporaryDatabase() -> (Database, String) {
        let path = NSTemporaryDirectory() + "test_atomic_\(UUID().uuidString).sqlite"
        let database = Database(databasePath: path)
        return (database, path)
    }

    private func cleanDatabase(path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    private func rowCount(
        table: String,
        databasePath: String
    ) throws -> Int {
        var connection: OpaquePointer?
        try #require(
            sqlite3_open_v2(
                databasePath,
                &connection,
                SQLITE_OPEN_READONLY,
                nil
            ) == SQLITE_OK
        )
        defer {
            sqlite3_close(connection)
        }

        var statement: OpaquePointer?
        try #require(
            sqlite3_prepare_v2(
                connection,
                "SELECT COUNT(*) FROM \(table);",
                -1,
                &statement,
                nil
            ) == SQLITE_OK
        )
        defer {
            sqlite3_finalize(statement)
        }

        try #require(sqlite3_step(statement) == SQLITE_ROW)
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func makeSnapshot(
        processes: [ProcessSnapshot] = []
    ) -> SystemSnapshot {
        SystemSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            cpu: 10,
            memory: 50,
            diskRead: 100,
            diskWrite: 200,
            networkIn: 300,
            networkOut: 400,
            processes: processes
        )
    }

    private func makeProcess(
        pid: Int32,
        memoryBytes: UInt64 = 1_048_576
    ) -> ProcessSnapshot {
        ProcessSnapshot(
            pid: pid,
            name: "process_\(pid)",
            cpuUsage: Double(pid),
            memoryBytes: memoryBytes,
            diskReadBytes: 1024,
            diskWriteBytes: 2048
        )
    }

    private func makeDiskEvent(
        bytes: UInt64 = 4096
    ) -> DiskProcessEvent {
        DiskProcessEvent(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            operation: "W",
            bytes: bytes,
            processName: "disk_process",
            pid: 77
        )
    }

    @Test("System, process and disk rows commit together")
    func testSuccessfulAtomicSnapshot() throws {
        let (database, path) = makeTemporaryDatabase()
        defer { cleanDatabase(path: path) }

        let snapshot = makeSnapshot(
            processes: [
                makeProcess(pid: 1),
                makeProcess(pid: 2)
            ]
        )
        let diskEvents = [
            makeDiskEvent(bytes: 4096),
            makeDiskEvent(bytes: 8192)
        ]

        let snapshotID = try #require(
            database.save(
                snapshot: snapshot,
                diskProcessEvents: diskEvents
            )
        )

        #expect(try rowCount(table: "system_samples", databasePath: path) == 1)
        #expect(try rowCount(table: "process_samples", databasePath: path) == 2)
        #expect(try rowCount(table: "disk_process_events", databasePath: path) == 2)
        #expect(database.getTopProcesses(snapshotID: snapshotID, limit: 5).count == 2)
        #expect(database.getDiskProcessEvents(snapshotID: snapshotID).count == 2)

        let ranking = database.getTopDiskProcesses(snapshotID: snapshotID)
        #expect(ranking.count == 1)
        #expect(ranking.first?.writeBytes == 12_288)
        #expect(ranking.first?.totalBytes == 12_288)
    }

    @Test("Process failure rolls back the whole snapshot")
    func testProcessFailureRollsBackSnapshot() throws {
        let (database, path) = makeTemporaryDatabase()
        defer { cleanDatabase(path: path) }

        let snapshot = makeSnapshot(
            processes: [
                makeProcess(pid: 1),
                makeProcess(pid: 2, memoryBytes: UInt64.max)
            ]
        )

        #expect(
            database.save(
                snapshot: snapshot,
                diskProcessEvents: [makeDiskEvent()]
            ) == nil
        )
        #expect(try rowCount(table: "system_samples", databasePath: path) == 0)
        #expect(try rowCount(table: "process_samples", databasePath: path) == 0)
        #expect(try rowCount(table: "disk_process_events", databasePath: path) == 0)
    }

    @Test("Disk event failure rolls back the whole snapshot")
    func testDiskEventFailureRollsBackSnapshot() throws {
        let (database, path) = makeTemporaryDatabase()
        defer { cleanDatabase(path: path) }

        let snapshot = makeSnapshot(processes: [makeProcess(pid: 1)])
        let diskEvents = [
            makeDiskEvent(bytes: 4096),
            makeDiskEvent(bytes: UInt64.max)
        ]

        #expect(
            database.save(
                snapshot: snapshot,
                diskProcessEvents: diskEvents
            ) == nil
        )
        #expect(try rowCount(table: "system_samples", databasePath: path) == 0)
        #expect(try rowCount(table: "process_samples", databasePath: path) == 0)
        #expect(try rowCount(table: "disk_process_events", databasePath: path) == 0)
    }

    @Test("Standalone disk batches are atomic too")
    func testStandaloneDiskBatchRollsBack() throws {
        let (database, path) = makeTemporaryDatabase()
        defer { cleanDatabase(path: path) }

        let inserted = database.saveDiskProcessEvents([
            makeDiskEvent(bytes: 4096),
            makeDiskEvent(bytes: UInt64.max)
        ])

        #expect(inserted == 0)
        #expect(try rowCount(table: "disk_process_events", databasePath: path) == 0)
    }

    @Test("Buffered fs_usage events are acknowledged only after persistence")
    func testBufferedEventsSurviveFailedSnapshot() throws {
        let (database, path) = makeTemporaryDatabase()
        defer { cleanDatabase(path: path) }

        let collector = FSUsageCollector()
        collector.processOutput(
            "21:55:20.000001    Write    D=0x1  B=0x100   /dev/disk1   0.000010 W procA.10"
        )
        let buffered = collector.getBufferedEvents()
        #expect(buffered.count == 1)

        let failingSnapshot = makeSnapshot(
            processes: [makeProcess(pid: 1, memoryBytes: UInt64.max)]
        )
        #expect(
            database.save(
                snapshot: failingSnapshot,
                diskProcessEvents: buffered
            ) == nil
        )
        #expect(collector.getBufferedEvents() == buffered)

        let snapshotID = try #require(
            database.save(
                snapshot: makeSnapshot(),
                diskProcessEvents: buffered
            )
        )
        collector.acknowledgeBufferedEvents(count: buffered.count)

        #expect(collector.getBufferedEvents().isEmpty)
        #expect(database.getDiskProcessEvents(snapshotID: snapshotID).count == 1)
    }
}

@Suite("Process Data Reliability Tests")
struct ProcessDataReliabilityTests {

    private func makeTemporaryDatabase() -> (Database, String) {
        let path = NSTemporaryDirectory() + "test_process_data_\(UUID().uuidString).sqlite"
        let database = Database(databasePath: path)
        return (database, path)
    }

    private func cleanDatabase(path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func queryPlanDetails(databasePath: String) throws -> [String] {
        var connection: OpaquePointer?
        try #require(
            sqlite3_open_v2(
                databasePath,
                &connection,
                SQLITE_OPEN_READONLY,
                nil
            ) == SQLITE_OK
        )
        defer {
            sqlite3_close(connection)
        }

        var statement: OpaquePointer?
        try #require(
            sqlite3_prepare_v2(
                connection,
                """
                EXPLAIN QUERY PLAN
                SELECT pid, name, cpu, memory, disk_read_bytes, disk_write_bytes
                FROM process_samples
                WHERE snapshot_id = 1
                ORDER BY cpu DESC
                LIMIT 5;
                """,
                -1,
                &statement,
                nil
            ) == SQLITE_OK
        )
        defer {
            sqlite3_finalize(statement)
        }

        var details: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let detailPointer = sqlite3_column_text(statement, 3) else {
                continue
            }
            details.append(String(cString: detailPointer))
        }
        return details
    }

    @Test("C bridge reads Disk I/O for the current process")
    func testCProcessRusageBridge() {
        var readBytes: UInt64 = 0
        var writeBytes: UInt64 = 0

        let result = get_process_disk_io(
            getpid(),
            &readBytes,
            &writeBytes
        )

        #expect(result == 0)
    }

    @Test("Baselines for missing PIDs are removed")
    func testMissingPIDBaselinesArePruned() {
        let collector = ProcessCollector()

        let firstSample = collector.sample()
        #expect(!firstSample.isEmpty)
        #expect(collector.trackedBaselineProcessCount > 0)

        collector.pruneBaselines(keeping: [])
        #expect(collector.trackedBaselineProcessCount == 0)

        let secondSample = collector.sample()
        #expect(!secondSample.isEmpty)
        #expect(collector.trackedBaselineProcessCount > 0)
    }

    @Test("Process baseline access is serialized")
    func testConcurrentBaselineAccess() {
        let collector = ProcessCollector()

        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            _ = collector.sample()
            _ = collector.trackedBaselineProcessCount
        }

        #expect(collector.trackedBaselineProcessCount > 0)
    }

    @Test("Snapshot CPU index preserves descending ranking")
    func testSnapshotCPUIndexPreservesRanking() throws {
        let (database, path) = makeTemporaryDatabase()
        defer { cleanDatabase(path: path) }

        let processes = [
            ProcessSnapshot(
                pid: 1,
                name: "low_cpu",
                cpuUsage: 1,
                memoryBytes: 100,
                diskReadBytes: 0,
                diskWriteBytes: 0
            ),
            ProcessSnapshot(
                pid: 2,
                name: "high_cpu",
                cpuUsage: 10,
                memoryBytes: 100,
                diskReadBytes: 0,
                diskWriteBytes: 0
            ),
            ProcessSnapshot(
                pid: 3,
                name: "medium_cpu",
                cpuUsage: 5,
                memoryBytes: 100,
                diskReadBytes: 0,
                diskWriteBytes: 0
            )
        ]
        let snapshot = SystemSnapshot(
            timestamp: Date(),
            cpu: 5,
            memory: 50,
            diskRead: 0,
            diskWrite: 0,
            networkIn: 0,
            networkOut: 0,
            processes: processes
        )
        let snapshotID = try #require(database.save(snapshot: snapshot))

        let ranked = database.getTopProcesses(snapshotID: snapshotID, limit: 3)
        #expect(ranked.map(\.name) == ["high_cpu", "medium_cpu", "low_cpu"])

        let plan = try queryPlanDetails(databasePath: path)
        #expect(plan.contains { $0.contains("idx_process_samples_snapshot_cpu") })
    }
}

@Suite("FSUsageCollector Reliability Tests")
struct FSUsageCollectorReliabilityTests {

    private let firstLine = "21:55:20.000001    Read    D=0x1  B=0x100   /dev/disk1   0.000001 R procA.10"
    private let secondLine = "21:55:21.000002    Write    D=0x2  B=0x200   /dev/disk1   0.000002 W procB.20"

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    private func shellConfiguration(
        _ command: String
    ) -> FSUsageLaunchConfiguration {
        FSUsageLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", command]
        )
    }

    @Test("Default fs_usage command is non-interactive")
    func testDefaultLaunchConfiguration() {
        let configuration = FSUsageLaunchConfiguration.fsUsage

        #expect(configuration.executableURL.path == "/usr/bin/sudo")
        #expect(configuration.arguments.first == "-n")
        #expect(configuration.arguments.contains("/usr/bin/fs_usage"))
        #expect(!configuration.arguments.contains("-S"))
    }

    @Test("Partial chunks are buffered until a complete line arrives")
    func testPartialChunks() {
        let collector = FSUsageCollector()

        collector.processOutputChunk("21:55:20.000001    Read    D=0x1  B=0x100   /dev/disk1   0.000001 R proc")
        #expect(collector.getBufferedEvents().isEmpty)

        collector.processOutputChunk("A.10\n21:55:21.000002    Write    D=0x2  B=0x200   /dev/disk1   0.000002 W procB.20")
        #expect(collector.getBufferedEvents().map(\.processName) == ["procA"])

        collector.processOutputChunk("\n")
        #expect(collector.getBufferedEvents().map(\.processName) == ["procA", "procB"])
    }

    @Test("Multiple lines, empty chunks and final unterminated lines are handled")
    func testChunkBoundariesAndEmptyChunks() {
        let collector = FSUsageCollector()

        collector.processOutputChunk("")
        collector.processOutputChunk(firstLine + "\n" + secondLine + "\n")
        #expect(collector.getBufferedEvents().count == 2)

        collector.processOutputChunk(
            "21:55:22.000003    Write    D=0x3  B=0x300   /dev/disk1   0.000003 W procC.30"
        )
        #expect(collector.getBufferedEvents().count == 2)

        collector.finishOutputStream()
        #expect(collector.getBufferedEvents().map(\.processName) == [
            "procA", "procB", "procC"
        ])
        #expect(collector.status.stdoutClosed)
    }

    @Test("Dropped events are counted when the bounded buffer is full")
    func testDroppedEventCounter() {
        let collector = FSUsageCollector(maxBufferSize: 2)

        collector.processOutput(firstLine + "\n" + secondLine + "\n" + "21:55:22.000003    Write    D=0x3  B=0x300   /dev/disk1   0.000003 W procC.30")

        #expect(collector.getBufferedEvents().count == 2)
        #expect(collector.droppedEventCount == 1)
    }

    @Test("Concurrent complete chunks do not corrupt the event buffer")
    func testConcurrentBufferAccess() {
        let collector = FSUsageCollector(maxBufferSize: 200)

        DispatchQueue.concurrentPerform(iterations: 100) { index in
            let line = "21:55:20.000001    Read    D=0x1  B=0x100   /dev/disk1   0.000001 R concurrent.\(index + 1)"
            collector.processOutputChunk(line + "\n")
        }

        #expect(collector.getBufferedEvents().count == 100)
        #expect(collector.droppedEventCount == 0)
    }

    @Test("Launch failure is distinct from a running process")
    func testLaunchFailureState() {
        let missingExecutable = URL(
            fileURLWithPath: "/private/var/m006-command-that-does-not-exist"
        )
        let collector = FSUsageCollector(
            launchConfiguration: FSUsageLaunchConfiguration(
                executableURL: missingExecutable,
                arguments: []
            )
        )

        collector.start()

        #expect(
            waitUntil {
                if case .launchFailed = collector.status.processState {
                    return true
                }
                return false
            }
        )
        #expect(!collector.isRunning)
        collector.stop()
        #expect(!collector.hasOpenPipes)
    }

    @Test("Immediate process termination exposes its exit code")
    func testImmediateTerminationState() {
        let collector = FSUsageCollector(
            launchConfiguration: shellConfiguration("exit 7")
        )

        collector.start()

        #expect(
            waitUntil {
                if case .terminated(let exitCode) = collector.status.processState {
                    return exitCode == 7
                }
                return false
            }
        )
        #expect(!collector.isRunning)
        collector.stop()
        #expect(collector.status.processState == .stopped)
        #expect(!collector.hasOpenPipes)
    }

    @Test("Running process stderr and permission failure are observable")
    func testRunningProcessAndPermissionState() {
        let collector = FSUsageCollector(
            launchConfiguration: shellConfiguration(
                "echo 'sudo: a password is required' >&2; sleep 1"
            )
        )

        collector.start()

        #expect(
            waitUntil {
                collector.status.stderrMessage.contains("password is required")
            }
        )
        #expect(collector.status.permissionDenied)
        #expect(collector.isRunning)
        #expect(collector.status.processState == .running)

        collector.stop()
        #expect(collector.status.processState == .stopped)
        #expect(!collector.hasOpenPipes)
    }

    @Test("Closing stdout is distinct from process termination")
    func testOutputPipeClosureState() {
        let collector = FSUsageCollector(
            launchConfiguration: shellConfiguration("exec 1>&-; sleep 1")
        )

        collector.start()

        #expect(waitUntil { collector.status.stdoutClosed })
        #expect(collector.status.processState == .outputPipeClosed)
        #expect(collector.isRunning)

        collector.stop()
        #expect(collector.status.processState == .stopped)
        #expect(!collector.hasOpenPipes)
    }

    @Test("Stop terminates a running process and closes its pipes")
    func testStopTerminatesProcess() {
        let collector = FSUsageCollector(
            launchConfiguration: shellConfiguration("sleep 5")
        )

        collector.start()
        #expect(waitUntil { collector.status.processState == .running })

        collector.stop()

        #expect(!collector.isRunning)
        #expect(collector.status.processState == .stopped)
        #expect(!collector.hasOpenPipes)
    }
}

@Suite("CPU and Mach Reliability Tests")
struct CPUAndMachReliabilityTests {

    @Test("First CPU sample establishes only a baseline")
    func testFirstSampleEstablishesBaseline() {
        let calculator = CPUUsageCalculator()

        #expect(calculator.update(with: CPUTicks(total: 100, idle: 50)) == 0)
        #expect(calculator.hasBaseline)
    }

    @Test("Second CPU sample uses the interval delta")
    func testSecondSampleUsesDelta() {
        let calculator = CPUUsageCalculator()

        _ = calculator.update(with: CPUTicks(total: 100, idle: 50))
        let usage = calculator.update(with: CPUTicks(total: 200, idle: 100))

        #expect(usage == 50)
    }

    @Test("Artificial tick variation produces the expected CPU percentage")
    func testTickVariationProducesExpectedUsage() {
        let calculator = CPUUsageCalculator()

        _ = calculator.update(with: CPUTicks(total: 1_000, idle: 800))
        let usage = calculator.update(with: CPUTicks(total: 1_200, idle: 820))

        // deltaTotal = 200, deltaIdle = 20 => 90% busy.
        #expect(usage == 90)
    }

    @Test("Zero total delta does not divide by zero")
    func testZeroTotalDelta() {
        let calculator = CPUUsageCalculator()

        _ = calculator.update(with: CPUTicks(total: 100, idle: 50))
        let usage = calculator.update(with: CPUTicks(total: 100, idle: 50))

        #expect(usage == 0)
    }

    @Test("Counter reset invalidates the interval safely")
    func testCounterReset() {
        let calculator = CPUUsageCalculator()

        _ = calculator.update(with: CPUTicks(total: 100, idle: 50))
        let usage = calculator.update(with: CPUTicks(total: 10, idle: 5))

        #expect(usage == 0)
        #expect(calculator.hasBaseline)
    }

    @Test("Mach processor info region uses the Mach deallocation contract")
    func testMachMemoryRegionDeallocationContract() {
        let region = MachMemoryRegion(
            address: vm_address_t(0x1234),
            integerCount: 4
        )
        var receivedAddress: vm_address_t = 0
        var receivedSize: vm_size_t = 0

        let result = region.deallocate { address, size in
            receivedAddress = address
            receivedSize = size
            return KERN_SUCCESS
        }

        #expect(result == KERN_SUCCESS)
        #expect(receivedAddress == region.address)
        #expect(receivedSize == region.size)
        #expect(region.size == vm_size_t(4 * MemoryLayout<integer_t>.size))
    }
}

@Suite("Database Performance and Retention Tests")
struct DatabasePerformanceAndRetentionTests {

    private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeTemporaryPath() -> String {
        NSTemporaryDirectory() + "test_retention_\(UUID().uuidString).sqlite"
    }

    private func cleanDatabase(path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    private func execute(_ sql: String, databasePath: String) throws {
        var connection: OpaquePointer?
        try #require(
            sqlite3_open_v2(
                databasePath,
                &connection,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
                nil
            ) == SQLITE_OK
        )
        defer {
            sqlite3_close(connection)
        }

        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(
            connection,
            sql,
            nil,
            nil,
            &errorMessage
        )

        guard result == SQLITE_OK else {
            let message = errorMessage.map {
                String(cString: $0)
            } ?? "unknown SQLite error"
            sqlite3_free(errorMessage)
            throw MigrationTestError.sqlite(message)
        }
    }

    private func readInteger(
        _ sql: String,
        databasePath: String
    ) throws -> Int64 {
        var connection: OpaquePointer?
        try #require(
            sqlite3_open_v2(
                databasePath,
                &connection,
                SQLITE_OPEN_READONLY,
                nil
            ) == SQLITE_OK
        )
        defer {
            sqlite3_close(connection)
        }

        var statement: OpaquePointer?
        try #require(
            sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK
        )
        defer {
            sqlite3_finalize(statement)
        }

        try #require(sqlite3_step(statement) == SQLITE_ROW)
        return sqlite3_column_int64(statement, 0)
    }

    private func readDouble(
        _ sql: String,
        databasePath: String
    ) throws -> Double {
        var connection: OpaquePointer?
        try #require(
            sqlite3_open_v2(
                databasePath,
                &connection,
                SQLITE_OPEN_READONLY,
                nil
            ) == SQLITE_OK
        )
        defer {
            sqlite3_close(connection)
        }

        var statement: OpaquePointer?
        try #require(
            sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK
        )
        defer {
            sqlite3_finalize(statement)
        }

        try #require(sqlite3_step(statement) == SQLITE_ROW)
        return sqlite3_column_double(statement, 0)
    }

    private func readString(
        _ sql: String,
        databasePath: String
    ) throws -> String {
        var connection: OpaquePointer?
        try #require(
            sqlite3_open_v2(
                databasePath,
                &connection,
                SQLITE_OPEN_READONLY,
                nil
            ) == SQLITE_OK
        )
        defer {
            sqlite3_close(connection)
        }

        var statement: OpaquePointer?
        try #require(
            sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK
        )
        defer {
            sqlite3_finalize(statement)
        }

        try #require(sqlite3_step(statement) == SQLITE_ROW)
        let pointer = try #require(sqlite3_column_text(statement, 0))
        return String(cString: pointer)
    }

    private func queryPlan(
        _ sql: String,
        databasePath: String
    ) throws -> [String] {
        var connection: OpaquePointer?
        try #require(
            sqlite3_open_v2(
                databasePath,
                &connection,
                SQLITE_OPEN_READONLY,
                nil
            ) == SQLITE_OK
        )
        defer {
            sqlite3_close(connection)
        }

        var statement: OpaquePointer?
        try #require(
            sqlite3_prepare_v2(
                connection,
                "EXPLAIN QUERY PLAN \(sql)",
                -1,
                &statement,
                nil
            ) == SQLITE_OK
        )
        defer {
            sqlite3_finalize(statement)
        }

        var details: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let pointer = sqlite3_column_text(statement, 3) else {
                continue
            }
            details.append(String(cString: pointer))
        }
        return details
    }

    private func makeSnapshot(
        at date: Date,
        cpu: Double = 20,
        memory: Double = 50,
        diskRead: Double = 100,
        diskWrite: Double = 200,
        networkIn: Double = 300,
        networkOut: Double = 400,
        processCount: Int = 1,
        includeDiskEvent: Bool = true,
        droppedEvents: Int = 0
    ) -> (SystemSnapshot, [DiskProcessEvent]) {
        var processes: [ProcessSnapshot] = []
        for index in 0..<processCount {
            let process = ProcessSnapshot(
                pid: Int32(index + 1),
                name: "process_\(index + 1)",
                cpuUsage: cpu + Double(index),
                memoryBytes: UInt64(1_000_000 * (index + 1)),
                diskReadBytes: UInt64(1_000 * (index + 1)),
                diskWriteBytes: UInt64(2_000 * (index + 1))
            )
            processes.append(process)
        }
        let events = includeDiskEvent
            ? [DiskProcessEvent(
                timestamp: date,
                operation: "W",
                bytes: 4096,
                processName: "process_1",
                pid: 1
            )]
            : []

        return (
            SystemSnapshot(
                timestamp: date,
                cpu: cpu,
                memory: memory,
                diskRead: diskRead,
                diskWrite: diskWrite,
                networkIn: networkIn,
                networkOut: networkOut,
                processes: processes,
                droppedEvents: droppedEvents
            ),
            events
        )
    }

    private func save(
        _ database: Database,
        at date: Date,
        cpu: Double = 20,
        memory: Double = 50,
        diskRead: Double = 100,
        diskWrite: Double = 200,
        networkIn: Double = 300,
        networkOut: Double = 400,
        processCount: Int = 1,
        includeDiskEvent: Bool = true,
        includeAnomaly: Bool = false,
        droppedEvents: Int = 0
    ) throws -> Int64 {
        let (snapshot, events) = makeSnapshot(
            at: date,
            cpu: cpu,
            memory: memory,
            diskRead: diskRead,
            diskWrite: diskWrite,
            networkIn: networkIn,
            networkOut: networkOut,
            processCount: processCount,
            includeDiskEvent: includeDiskEvent,
            droppedEvents: droppedEvents
        )
        let snapshotID = try #require(
            database.save(snapshot: snapshot, diskProcessEvents: events)
        )
        if includeAnomaly {
            database.saveEvent(
                DetectedEvent(
                    type: "TEST_EVENT",
                    severity: "info",
                    value: 1,
                    message: "test"
                ),
                snapshotID: snapshotID,
                timestamp: date
            )
        }
        return snapshotID
    }

    private func totalDatabaseBytes(path: String) -> Int {
        [path, path + "-wal", path + "-shm"]
            .compactMap { try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? NSNumber }
            .compactMap { $0?.intValue }
            .reduce(0, +)
    }

    @Test("Schema, WAL and maintenance indexes are available")
    func testSchemaWALAndIndexes() throws {
        let path = makeTemporaryPath()
        defer { cleanDatabase(path: path) }

        let database = Database(databasePath: path, logWrites: false)
        #expect(database.journalMode.lowercased() == "wal")
        #expect(try readString("PRAGMA journal_mode;", databasePath: path).lowercased() == "wal")
        #expect(try readInteger("PRAGMA user_version;", databasePath: path) == 4)
        #expect(try readInteger("SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='idx_system_samples_timestamp';", databasePath: path) == 1)
        #expect(try readInteger("SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='idx_events_snapshot_id';", databasePath: path) == 1)
        #expect(try readInteger("SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='idx_process_samples_snapshot_cpu';", databasePath: path) == 1)
        #expect(try readInteger("SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='idx_disk_process_events_snapshot_id';", databasePath: path) == 1)
        #expect(try readInteger("SELECT COUNT(*) FROM pragma_table_info('system_samples') WHERE name='dropped_events';", databasePath: path) == 1)

        _ = try save(database, at: referenceDate)
        #expect(try database.checkpoint())

        let processPlan = try queryPlan(
            "SELECT pid, name, cpu FROM process_samples WHERE snapshot_id = 1 ORDER BY cpu DESC LIMIT 5;",
            databasePath: path
        )
        #expect(processPlan.contains { $0.contains("idx_process_samples_snapshot_cpu") })

        let diskPlan = try queryPlan(
            "SELECT process_name, pid, SUM(bytes) FROM disk_process_events WHERE snapshot_id = 1 GROUP BY process_name, pid;",
            databasePath: path
        )
        #expect(diskPlan.contains { $0.contains("idx_disk_process_events_snapshot_id") })

        let retentionPlan = try queryPlan(
            "DELETE FROM system_samples WHERE timestamp < 1;",
            databasePath: path
        )
        #expect(retentionPlan.contains { $0.contains("idx_system_samples_timestamp") })
    }

    @Test("Maintenance interval is configurable through retention policy")
    func testMaintenanceIntervalConfiguration() throws {
        let path = makeTemporaryPath()
        defer { cleanDatabase(path: path) }

        let database = Database(
            databasePath: path,
            retentionPolicy: DatabaseRetentionPolicy(
                detailedRetentionDays: 1,
                hourlyRetentionDays: 2,
                dailyRetentionDays: 3,
                maintenanceInterval: 60
            ),
            logWrites: false
        )

        #expect(database.maintenanceInterval == 60)
    }

    @Test("Actual version 1 migration adds dropped column and dirty queue")
    func testActualVersionOneMigration() throws {
        let path = makeTemporaryPath()
        defer { cleanDatabase(path: path) }

        try execute(
            """
            CREATE TABLE system_samples (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp REAL NOT NULL,
                cpu REAL NOT NULL,
                memory REAL NOT NULL,
                disk_read REAL NOT NULL,
                disk_write REAL NOT NULL,
                network_in REAL NOT NULL,
                network_out REAL NOT NULL
            );
            CREATE TABLE process_samples (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                snapshot_id INTEGER NOT NULL,
                timestamp REAL NOT NULL,
                pid INTEGER NOT NULL,
                name TEXT NOT NULL,
                cpu REAL NOT NULL,
                memory INTEGER NOT NULL,
                FOREIGN KEY(snapshot_id) REFERENCES system_samples(id)
            );
            CREATE TABLE events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                snapshot_id INTEGER NOT NULL,
                timestamp REAL NOT NULL,
                type TEXT NOT NULL,
                severity TEXT NOT NULL,
                value REAL NOT NULL,
                message TEXT NOT NULL,
                FOREIGN KEY(snapshot_id) REFERENCES system_samples(id)
            );
            PRAGMA user_version = 1;
            """,
            databasePath: path
        )

        let database = Database(databasePath: path, logWrites: false)
        #expect(try readInteger("PRAGMA user_version;", databasePath: path) == 4)
        #expect(try readInteger("SELECT COUNT(*) FROM pragma_table_info('system_samples') WHERE name='dropped_events';", databasePath: path) == 1)
        #expect(try readInteger("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='maintenance_dirty_buckets';", databasePath: path) == 1)

        let snapshot = SystemSnapshot(
            timestamp: referenceDate,
            cpu: 10,
            memory: 20,
            diskRead: 30,
            diskWrite: 40,
            networkIn: 50,
            networkOut: 60,
            processes: [],
            droppedEvents: 4
        )
        #expect(database.save(snapshot: snapshot) != nil)
        #expect(try readInteger("SELECT dropped_events FROM system_samples ORDER BY id DESC LIMIT 1;", databasePath: path) == 4)
    }

    @Test("Schema version 2 migrates to dirty bucket maintenance")
    func testVersionTwoMigration() throws {
        let path = makeTemporaryPath()
        defer { cleanDatabase(path: path) }

        do {
            let database = Database(databasePath: path, logWrites: false)
            let snapshotID = try #require(
                database.save(snapshot: makeSnapshot(at: referenceDate).0)
            )
            #expect(snapshotID > 0)
        }
        try execute(
            """
            DROP INDEX idx_disk_process_events_standalone_timestamp;
            DROP INDEX idx_process_samples_timestamp;
            DROP TABLE maintenance_dirty_buckets;
            CREATE INDEX idx_disk_process_events_timestamp
                ON disk_process_events(timestamp);
            PRAGMA user_version = 2;
            """,
            databasePath: path
        )

        let migrated = Database(databasePath: path, logWrites: false)
        #expect(try readInteger("PRAGMA user_version;", databasePath: path) == 4)
        #expect(try readInteger("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='maintenance_dirty_buckets';", databasePath: path) == 1)
        #expect(try readInteger("SELECT COUNT(*) FROM maintenance_dirty_buckets;", databasePath: path) > 0)
        #expect(try migrated.performMaintenance(now: referenceDate).remainingDirtyBuckets == 0)
        #expect(migrated.journalMode.lowercased() == "wal")
    }

    @Test("Schema version 3 repairs the legacy standalone disk index")
    func testVersionThreeIndexRepair() throws {
        let path = makeTemporaryPath()
        defer { cleanDatabase(path: path) }

        let initialID: Int64
        do {
            let database = Database(databasePath: path, logWrites: false)
            initialID = try #require(
                database.save(
                    snapshot: makeSnapshot(at: referenceDate).0,
                    diskProcessEvents: []
                )
            )
        }

        try execute(
            """
            DROP INDEX idx_disk_process_events_standalone_timestamp;
            CREATE INDEX idx_disk_process_events_timestamp
                ON disk_process_events(timestamp);
            PRAGMA user_version = 3;
            """,
            databasePath: path
        )

        let migrated = Database(databasePath: path, logWrites: false)
        #expect(try readInteger("PRAGMA user_version;", databasePath: path) == 4)
        #expect(try readInteger("SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='idx_disk_process_events_standalone_timestamp';", databasePath: path) == 1)
        #expect(try readInteger("SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='idx_disk_process_events_timestamp';", databasePath: path) == 0)
        #expect(try migrated.performMaintenance(now: referenceDate).remainingDirtyBuckets == 0)
        #expect(try readInteger("SELECT COUNT(*) FROM system_samples WHERE id = \(initialID);", databasePath: path) == 1)
    }

    @Test("Checkpoint reports an incomplete WAL while a reader is active")
    func testCheckpointReportsBusyReader() throws {
        let path = makeTemporaryPath()
        defer { cleanDatabase(path: path) }

        let database = Database(databasePath: path, logWrites: false)
        var reader: OpaquePointer?
        try #require(
            sqlite3_open_v2(
                path,
                &reader,
                SQLITE_OPEN_READONLY,
                nil
            ) == SQLITE_OK
        )
        defer {
            sqlite3_close(reader)
        }

        try #require(
            sqlite3_exec(
                reader,
                "BEGIN; SELECT COUNT(*) FROM system_samples;",
                nil,
                nil,
                nil
            ) == SQLITE_OK
        )
        let snapshotID = try #require(
            database.save(snapshot: makeSnapshot(at: referenceDate).0)
        )
        #expect(snapshotID > 0)
        #expect(try database.checkpoint() == false)
        try #require(
            sqlite3_exec(reader, "ROLLBACK;", nil, nil, nil) == SQLITE_OK
        )
    }

    @Test("Schema version 1 migrates to aggregates and retention indexes")
    func testVersionOneMigration() throws {
        let path = makeTemporaryPath()
        defer { cleanDatabase(path: path) }

        do {
            _ = Database(databasePath: path, logWrites: false)
        }
        try execute(
            """
            DROP TABLE hourly_process_stats;
            DROP TABLE daily_process_stats;
            DROP TABLE hourly_system_stats;
            DROP TABLE daily_system_stats;
            DROP INDEX idx_system_samples_timestamp;
            DROP INDEX idx_process_samples_timestamp;
            DROP INDEX idx_disk_process_events_standalone_timestamp;
            DROP INDEX idx_events_snapshot_id;
            DROP TABLE maintenance_dirty_buckets;
            PRAGMA user_version = 1;
            """,
            databasePath: path
        )

        let migrated = Database(databasePath: path, logWrites: false)
        #expect(try readInteger("PRAGMA user_version;", databasePath: path) == 4)
        #expect(try readInteger("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='hourly_system_stats';", databasePath: path) == 1)
        #expect(try readInteger("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='maintenance_dirty_buckets';", databasePath: path) == 1)
        #expect(try readInteger("SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='idx_system_samples_timestamp';", databasePath: path) == 1)
        #expect(try readInteger("SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='idx_process_samples_timestamp';", databasePath: path) == 1)
        #expect(migrated.journalMode.lowercased() == "wal")
    }

    @Test("Retention preserves the exact cutoff and removes older detail")
    func testRetentionBoundaries() throws {
        let path = makeTemporaryPath()
        defer { cleanDatabase(path: path) }

        let now = referenceDate
        let cutoff = now.addingTimeInterval(-2 * 86_400)
        let policy = DatabaseRetentionPolicy(
            detailedRetentionDays: 2,
            hourlyRetentionDays: 30,
            dailyRetentionDays: 365
        )
        let database = Database(
            databasePath: path,
            retentionPolicy: policy,
            logWrites: false
        )

        _ = try save(database, at: cutoff - 1, includeAnomaly: true)
        _ = try save(database, at: cutoff, includeAnomaly: true)
        _ = try save(database, at: cutoff + 1, includeAnomaly: true)
        _ = try save(database, at: now, includeAnomaly: true)

        let report = try database.performMaintenance(now: now)
        #expect(report.deletedSystemSamples == 1)
        #expect(report.deletedProcessSamples == 1)
        #expect(report.deletedDiskProcessEvents == 1)
        #expect(report.deletedEvents == 1)
        #expect(try readInteger("SELECT COUNT(*) FROM system_samples;", databasePath: path) == 3)
        #expect(try readInteger("SELECT COUNT(*) FROM process_samples;", databasePath: path) == 3)
        #expect(try readInteger("SELECT COUNT(*) FROM disk_process_events;", databasePath: path) == 3)
        #expect(try readInteger("SELECT COUNT(*) FROM events;", databasePath: path) == 3)
        #expect(try readInteger("SELECT COUNT(*) FROM hourly_system_stats;", databasePath: path) > 0)
    }

    @Test("Maintenance aggregates hourly and daily statistics")
    func testAggregation() throws {
        let path = makeTemporaryPath()
        defer { cleanDatabase(path: path) }

        let policy = DatabaseRetentionPolicy(
            detailedRetentionDays: 7,
            hourlyRetentionDays: 30,
            dailyRetentionDays: 365
        )
        let database = Database(
            databasePath: path,
            retentionPolicy: policy,
            logWrites: false
        )
        let first = referenceDate
        let second = first.addingTimeInterval(40 * 60)
        let nextDay = first.addingTimeInterval(24 * 60 * 60)

        _ = try save(
            database,
            at: first,
            cpu: 20,
            memory: 50,
            diskRead: 100,
            diskWrite: 200,
            includeAnomaly: true,
            droppedEvents: 3
        )
        _ = try save(
            database,
            at: second,
            cpu: 40,
            memory: 70,
            diskRead: 300,
            diskWrite: 500,
            includeDiskEvent: true,
            droppedEvents: 5
        )
        _ = try save(
            database,
            at: nextDay,
            cpu: 30,
            memory: 60,
            diskRead: 200,
            diskWrite: 400,
            includeDiskEvent: true,
            droppedEvents: 2
        )

        let report = try database.performMaintenance(now: nextDay)
        #expect(report.refreshedHourlySystemStats == 2)
        #expect(report.refreshedDailySystemStats == 2)
        #expect(report.refreshedHourlyProcessStats == 2)
        #expect(report.refreshedDailyProcessStats == 2)
        #expect(try readInteger("SELECT COUNT(*) FROM hourly_system_stats;", databasePath: path) == 2)
        #expect(try readInteger("SELECT COUNT(*) FROM daily_system_stats;", databasePath: path) == 2)
        #expect(try readInteger("SELECT COUNT(*) FROM hourly_process_stats;", databasePath: path) == 2)
        #expect(try readInteger("SELECT COUNT(*) FROM daily_process_stats;", databasePath: path) == 2)

        #expect(try readDouble("SELECT cpu_avg FROM hourly_system_stats ORDER BY bucket_start LIMIT 1;", databasePath: path) == 30)
        #expect(try readDouble("SELECT cpu_max FROM hourly_system_stats ORDER BY bucket_start LIMIT 1;", databasePath: path) == 40)
        #expect(try readDouble("SELECT memory_avg FROM hourly_system_stats ORDER BY bucket_start LIMIT 1;", databasePath: path) == 60)
        #expect(try readDouble("SELECT disk_read_sum FROM hourly_system_stats ORDER BY bucket_start LIMIT 1;", databasePath: path) == 400)
        #expect(try readDouble("SELECT cpu_avg FROM hourly_process_stats ORDER BY bucket_start LIMIT 1;", databasePath: path) == 30)
        #expect(try readInteger("SELECT disk_event_count FROM hourly_system_stats ORDER BY bucket_start LIMIT 1;", databasePath: path) == 2)
        #expect(try readInteger("SELECT anomaly_count FROM hourly_system_stats ORDER BY bucket_start LIMIT 1;", databasePath: path) == 1)
        #expect(try readInteger("SELECT dropped_events_sum FROM hourly_system_stats ORDER BY bucket_start LIMIT 1;", databasePath: path) == 8)
    }

    @Test("Standalone disk events contribute to aggregate disk totals")
    func testStandaloneDiskEventsAreAggregated() throws {
        let path = makeTemporaryPath()
        defer { cleanDatabase(path: path) }

        let database = Database(databasePath: path, logWrites: false)
        _ = try save(database, at: referenceDate)

        let standalone = DiskProcessEvent(
            timestamp: referenceDate,
            operation: "W",
            bytes: 123,
            processName: "standalone",
            pid: 999
        )
        #expect(database.saveDiskProcessEvent(standalone))

        let standaloneDate = referenceDate.addingTimeInterval(2 * 3_600)
        let standaloneOnly = DiskProcessEvent(
            timestamp: standaloneDate,
            operation: "R",
            bytes: 777,
            processName: "standalone-only",
            pid: 1000
        )
        #expect(database.saveDiskProcessEvent(standaloneOnly))

        let report = try database.performMaintenance(now: standaloneDate)
        let standaloneBucket = floor(
            standaloneDate.timeIntervalSince1970 / 3_600
        ) * 3_600
        #expect(report.remainingDirtyBuckets == 0)
        #expect(try readInteger("SELECT COUNT(*) FROM hourly_system_stats;", databasePath: path) == 2)
        #expect(try readInteger("SELECT disk_event_count FROM hourly_system_stats ORDER BY bucket_start LIMIT 1;", databasePath: path) == 2)
        #expect(try readInteger("SELECT disk_event_bytes FROM hourly_system_stats ORDER BY bucket_start LIMIT 1;", databasePath: path) == 4_219)
        #expect(try readInteger("SELECT disk_event_count FROM hourly_system_stats WHERE bucket_start = \(standaloneBucket);", databasePath: path) == 1)
        #expect(try readInteger("SELECT disk_event_bytes FROM hourly_system_stats WHERE bucket_start = \(standaloneBucket);", databasePath: path) == 777)
    }

    @Test("Linked events mark the snapshot bucket, not the event timestamp")
    func testLinkedEventsUseSnapshotBucket() throws {
        let path = makeTemporaryPath()
        defer { cleanDatabase(path: path) }

        let database = Database(databasePath: path, logWrites: false)
        let snapshotID = try #require(
            database.save(snapshot: makeSnapshot(at: referenceDate).0)
        )
        _ = try database.performMaintenance(now: referenceDate)

        let laterDate = referenceDate.addingTimeInterval(2 * 3_600)
        database.saveEvent(
            DetectedEvent(
                type: "TEST_EVENT",
                severity: "info",
                value: 1,
                message: "linked"
            ),
            snapshotID: snapshotID,
            timestamp: laterDate
        )
        #expect(database.saveDiskProcessEvent(
            DiskProcessEvent(
                timestamp: laterDate,
                operation: "W",
                bytes: 10,
                processName: "linked",
                pid: 1
            ),
            snapshotID: snapshotID
        ))

        _ = try database.performMaintenance(now: laterDate)
        #expect(try readInteger("SELECT COUNT(*) FROM hourly_system_stats;", databasePath: path) == 1)
        #expect(try readInteger("SELECT disk_event_count FROM hourly_system_stats;", databasePath: path) == 1)
        #expect(try readInteger("SELECT anomaly_count FROM hourly_system_stats;", databasePath: path) == 1)
    }

    @Test("Aggregate retention keeps buckets containing the cutoff")
    func testAggregateRetentionBoundaries() throws {
        let path = makeTemporaryPath()
        defer { cleanDatabase(path: path) }

        let alignedReference = floor(
            referenceDate.timeIntervalSince1970 / 3_600
        ) * 3_600
        let cutoff = alignedReference - 2 * 86_400
        let now = cutoff + 2 * 86_400
        let policy = DatabaseRetentionPolicy(
            detailedRetentionDays: 30,
            hourlyRetentionDays: 2,
            dailyRetentionDays: 2,
            maintenanceInterval: 60
        )
        let database = Database(
            databasePath: path,
            retentionPolicy: policy,
            logWrites: false
        )

        _ = try save(database, at: Date(timeIntervalSince1970: cutoff - 1))
        _ = try save(database, at: Date(timeIntervalSince1970: cutoff))
        _ = try save(database, at: Date(timeIntervalSince1970: cutoff + 3_600))

        let report = try database.performMaintenance(
            now: Date(timeIntervalSince1970: now)
        )

        #expect(report.deletedHourlySystemStats == 1)
        #expect(report.deletedDailySystemStats == 0)
        #expect(try readInteger("SELECT COUNT(*) FROM hourly_system_stats;", databasePath: path) == 2)
        #expect(try readInteger("SELECT COUNT(*) FROM daily_system_stats;", databasePath: path) == 1)
    }

    @Test("Maintenance bounds dirty aggregate work per transaction")
    func testMaintenanceBoundsDirtyBuckets() throws {
        let path = makeTemporaryPath()
        defer { cleanDatabase(path: path) }

        let database = Database(
            databasePath: path,
            retentionPolicy: DatabaseRetentionPolicy(
                detailedRetentionDays: 0,
                hourlyRetentionDays: 30,
                dailyRetentionDays: 365
            ),
            logWrites: false
        )
        for hour in 0..<40 {
            _ = try save(
                database,
                at: referenceDate.addingTimeInterval(Double(hour) * 3_600)
            )
        }

        let first = try database.performMaintenance(
            now: referenceDate.addingTimeInterval(40 * 3_600)
        )
        #expect(first.processedDirtyBuckets == 32)
        #expect(first.remainingDirtyBuckets > 0)
        #expect(first.deletedSystemSamples == 0)

        var remaining = first.remainingDirtyBuckets
        var iterations = 0
        var deletedSystemSamples = 0
        while remaining > 0 && iterations < 10 {
            let report = try database.performMaintenance(
                now: referenceDate.addingTimeInterval(40 * 3_600)
            )
            remaining = report.remainingDirtyBuckets
            deletedSystemSamples += report.deletedSystemSamples
            iterations += 1
        }

        #expect(remaining == 0)
        #expect(deletedSystemSamples > 0)
        #expect(iterations < 10)
    }

    @Test("Repeated maintenance is idempotent")
    func testMaintenanceIsIdempotent() throws {
        let path = makeTemporaryPath()
        defer { cleanDatabase(path: path) }

        let policy = DatabaseRetentionPolicy(
            detailedRetentionDays: 1,
            hourlyRetentionDays: 30,
            dailyRetentionDays: 365
        )
        let database = Database(
            databasePath: path,
            retentionPolicy: policy,
            logWrites: false
        )
        _ = try save(database, at: referenceDate - 3 * 86_400)
        _ = try save(database, at: referenceDate)

        let first = try database.performMaintenance(now: referenceDate)
        let aggregateCount = try readInteger(
            "SELECT COUNT(*) FROM daily_system_stats;",
            databasePath: path
        )
        let second = try database.performMaintenance(now: referenceDate)

        #expect(first.deletedSystemSamples == 1)
        #expect(second.totalDeleted == 0)
        #expect(try readInteger("SELECT COUNT(*) FROM daily_system_stats;", databasePath: path) == aggregateCount)
        #expect(second.refreshedDailySystemStats == 0)
        #expect(second.processedDirtyBuckets == 0)
    }

    @Test("Maintenance on an empty database is safe")
    func testMaintenanceOnEmptyDatabase() throws {
        let path = makeTemporaryPath()
        defer { cleanDatabase(path: path) }

        let database = Database(databasePath: path, logWrites: false)
        let report = try database.performMaintenance(now: referenceDate)

        #expect(report.totalDeleted == 0)
        #expect(try readInteger("SELECT COUNT(*) FROM hourly_system_stats;", databasePath: path) == 0)
        #expect(try readInteger("SELECT COUNT(*) FROM daily_system_stats;", databasePath: path) == 0)
    }

    @Test("Maintenance rolls back when aggregation fails")
    func testMaintenanceRollback() throws {
        let path = makeTemporaryPath()
        defer { cleanDatabase(path: path) }

        let policy = DatabaseRetentionPolicy(
            detailedRetentionDays: 1,
            hourlyRetentionDays: 30,
            dailyRetentionDays: 365
        )
        let database = Database(
            databasePath: path,
            retentionPolicy: policy,
            logWrites: false
        )
        _ = try save(database, at: referenceDate - 3 * 86_400)
        _ = try save(database, at: referenceDate)
        try execute(
            """
            CREATE TRIGGER fail_hourly_aggregate
            BEFORE INSERT ON hourly_system_stats
            BEGIN
                SELECT RAISE(ABORT, 'forced maintenance failure');
            END;
            """,
            databasePath: path
        )

        var didThrow = false
        do {
            _ = try database.performMaintenance(now: referenceDate)
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        #expect(try readInteger("SELECT COUNT(*) FROM system_samples;", databasePath: path) == 2)
        #expect(try readInteger("SELECT COUNT(*) FROM process_samples;", databasePath: path) == 2)
    }

    @Test("Retention and aggregation query plans use intended indexes")
    func testRetentionQueryPlans() throws {
        let path = makeTemporaryPath()
        defer { cleanDatabase(path: path) }

        let database = Database(databasePath: path, logWrites: false)
        _ = try save(database, at: referenceDate, processCount: 2)

        let processPlan = try queryPlan(
            "SELECT pid, name, cpu FROM process_samples WHERE snapshot_id = 1 ORDER BY cpu DESC LIMIT 5;",
            databasePath: path
        )
        #expect(processPlan.contains { $0.contains("idx_process_samples_snapshot_cpu") })

        let processTimestampPlan = try queryPlan(
            "SELECT pid, name FROM process_samples WHERE timestamp >= 0 AND timestamp < 1 GROUP BY pid, name;",
            databasePath: path
        )
        #expect(processTimestampPlan.contains { $0.contains("idx_process_samples_timestamp") })

        let systemTimestampPlan = try queryPlan(
            "SELECT id FROM system_samples WHERE timestamp >= 0 AND timestamp < 1;",
            databasePath: path
        )
        #expect(systemTimestampPlan.contains { $0.contains("idx_system_samples_timestamp") })

        let standaloneDiskPlan = try queryPlan(
            "SELECT bytes FROM disk_process_events INDEXED BY idx_disk_process_events_standalone_timestamp WHERE snapshot_id IS NULL AND timestamp >= 0 AND timestamp < 1;",
            databasePath: path
        )
        #expect(standaloneDiskPlan.contains { $0.contains("idx_disk_process_events_standalone_timestamp") })

        let diskPlan = try queryPlan(
            "SELECT process_name, pid, SUM(bytes) FROM disk_process_events WHERE snapshot_id = 1 GROUP BY process_name, pid;",
            databasePath: path
        )
        #expect(diskPlan.contains { $0.contains("idx_disk_process_events_snapshot_id") })

        let eventPlan = try queryPlan(
            "DELETE FROM events WHERE snapshot_id IN (SELECT id FROM system_samples WHERE timestamp < 1);",
            databasePath: path
        )
        #expect(eventPlan.contains { $0.contains("idx_events_snapshot_id") })

        let dirtyPlan = try queryPlan(
            "SELECT granularity, bucket_start FROM maintenance_dirty_buckets INDEXED BY idx_maintenance_dirty_buckets_bucket_start ORDER BY bucket_start, granularity LIMIT 32;",
            databasePath: path
        )
        #expect(dirtyPlan.contains { $0.contains("idx_maintenance_dirty_buckets_bucket_start") })

        let aggregateRetentionPlan = try queryPlan(
            "DELETE FROM hourly_system_stats WHERE bucket_start <= 1;",
            databasePath: path
        )
        #expect(aggregateRetentionPlan.contains { $0.contains("SEARCH") })
    }

    @Test("Foreign keys remain enforced after maintenance")
    func testForeignKeysAfterMaintenance() throws {
        let path = makeTemporaryPath()
        defer { cleanDatabase(path: path) }

        let database = Database(databasePath: path, logWrites: false)
        _ = try save(database, at: referenceDate)
        _ = try database.performMaintenance(now: referenceDate)

        let orphan = DiskProcessEvent(
            timestamp: referenceDate,
            operation: "W",
            bytes: 1,
            processName: "orphan",
            pid: 999
        )
        #expect(!database.saveDiskProcessEvent(orphan, snapshotID: 999_999))
    }

    @Test("Synthetic benchmark covers 1,000 and 10,000 snapshots")
    func testSyntheticBenchmark() throws {
        let results = try benchmark(snapshotCount: 1_000)
        let largeResults = try benchmark(snapshotCount: 10_000)

        print(
            "M007 benchmark 1k: insert=\(results.insertSeconds)s ranking=\(results.rankingSeconds)s maintenance=\(results.maintenanceSeconds)s bytes_before=\(results.bytesBeforeMaintenance) bytes_after=\(results.bytesAfterMaintenance)"
        )
        print(
            "M007 benchmark 10k: insert=\(largeResults.insertSeconds)s ranking=\(largeResults.rankingSeconds)s maintenance=\(largeResults.maintenanceSeconds)s bytes_before=\(largeResults.bytesBeforeMaintenance) bytes_after=\(largeResults.bytesAfterMaintenance)"
        )

        #expect(results.insertedSystemRows == 1_000)
        #expect(largeResults.insertedSystemRows == 10_000)
        #expect(largeResults.rankingCount == 1)
        #expect(largeResults.deletedRows > 0)
        #expect(largeResults.systemRows == 0)
        #expect(largeResults.remainingDirtyBuckets == 0)
        #expect(largeResults.bytesBeforeMaintenance > 0)
        #expect(largeResults.bytesAfterMaintenance > 0)
        #expect(largeResults.insertSeconds.isFinite)
        #expect(largeResults.rankingSeconds.isFinite)
        #expect(largeResults.maintenanceSeconds.isFinite)
        #expect(largeResults.insertSeconds < 30)
        #expect(largeResults.maintenanceSeconds < 10)
    }

    private struct BenchmarkResult {
        let insertSeconds: Double
        let rankingSeconds: Double
        let maintenanceSeconds: Double
        let bytesBeforeMaintenance: Int
        let bytesAfterMaintenance: Int
        let insertedSystemRows: Int64
        let systemRows: Int64
        let rankingCount: Int
        let deletedRows: Int
        let remainingDirtyBuckets: Int
    }

    private func benchmark(snapshotCount: Int) throws -> BenchmarkResult {
        let path = makeTemporaryPath()
        defer { cleanDatabase(path: path) }

        let policy = DatabaseRetentionPolicy(
            detailedRetentionDays: 2,
            hourlyRetentionDays: 30,
            dailyRetentionDays: 365
        )
        let database = Database(
            databasePath: path,
            retentionPolicy: policy,
            logWrites: false
        )
        let startDate = referenceDate
        var lastSnapshotID: Int64?

        let insertStart = Date()
        for index in 0..<snapshotCount {
            let date = startDate.addingTimeInterval(Double(index) * 2)
            lastSnapshotID = try save(
                database,
                at: date,
                cpu: Double(index % 100),
                memory: Double(40 + index % 30),
                diskRead: Double(100 + index % 1000),
                diskWrite: Double(200 + index % 1000),
                processCount: 5,
                includeDiskEvent: true
            )
        }
        let insertSeconds = Date().timeIntervalSince(insertStart)

        let rankingStart = Date()
        let ranking = database.getTopDiskProcesses(
            snapshotID: lastSnapshotID,
            limit: 3
        )
        let rankingSeconds = Date().timeIntervalSince(rankingStart)
        let insertedSystemRows = try readInteger(
            "SELECT COUNT(*) FROM system_samples;",
            databasePath: path
        )
        let bytesBeforeMaintenance = totalDatabaseBytes(path: path)

        let maintenanceStart = Date()
        let report = try database.performMaintenance(
            now: startDate.addingTimeInterval(4 * 86_400)
        )
        #expect(try database.checkpoint())
        let maintenanceSeconds = Date().timeIntervalSince(maintenanceStart)

        return BenchmarkResult(
            insertSeconds: insertSeconds,
            rankingSeconds: rankingSeconds,
            maintenanceSeconds: maintenanceSeconds,
            bytesBeforeMaintenance: bytesBeforeMaintenance,
            bytesAfterMaintenance: totalDatabaseBytes(path: path),
            insertedSystemRows: insertedSystemRows,
            systemRows: try readInteger(
                "SELECT COUNT(*) FROM system_samples;",
                databasePath: path
            ),
            rankingCount: ranking.count,
            deletedRows: report.totalDeleted,
            remainingDirtyBuckets: report.remainingDirtyBuckets
        )
    }
}

private enum MigrationTestError: Error {
    case sqlite(String)
}

private let sqliteTransientForTests = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)

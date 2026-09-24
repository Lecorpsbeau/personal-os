import Foundation
import SQLite3
import Testing
@testable import mac_detective

@Suite("Detector Reliability Tests")
struct DetectorReliabilityTests {

    private let baseDate = Date(timeIntervalSince1970: 1_900_000_000)

    private func date(_ offset: TimeInterval) -> Date {
        baseDate.addingTimeInterval(offset)
    }

    private func snapshot(
        at timestamp: Date? = nil,
        cpu: Double = 0,
        memory: Double = 0,
        diskRead: Double = 0,
        diskWrite: Double = 0,
        networkIn: Double = 0,
        networkOut: Double = 0,
        processes: [ProcessSnapshot] = []
    ) -> SystemSnapshot {
        SystemSnapshot(
            timestamp: timestamp ?? baseDate,
            cpu: cpu,
            memory: memory,
            diskRead: diskRead,
            diskWrite: diskWrite,
            networkIn: networkIn,
            networkOut: networkOut,
            processes: processes
        )
    }

    private func process(
        pid: Int32,
        name: String,
        readBytes: UInt64 = 0,
        writeBytes: UInt64 = 0
    ) -> ProcessSnapshot {
        ProcessSnapshot(
            pid: pid,
            name: name,
            cpuUsage: 0,
            memoryBytes: 0,
            diskReadBytes: readBytes,
            diskWriteBytes: writeBytes
        )
    }

    private func configuration(
        cpu: Double = 1_000_000,
        memory: Double = 1_000_000,
        diskRead: Double = 1_000_000_000,
        diskWrite: Double = 1_000_000_000,
        network: Double = 1_000_000_000,
        processRead: Double = 1_000_000_000,
        processWrite: Double = 1_000_000_000,
        cooldown: TimeInterval = 60
    ) -> DetectorConfiguration {
        DetectorConfiguration(
            cpuThreshold: cpu,
            memoryThreshold: memory,
            diskReadThreshold: diskRead,
            diskWriteThreshold: diskWrite,
            networkThreshold: network,
            processDiskReadThreshold: processRead,
            processDiskWriteThreshold: processWrite,
            cpuClearThreshold: 0,
            memoryClearThreshold: 0,
            diskReadClearThreshold: 0,
            diskWriteClearThreshold: 0,
            networkClearThreshold: 0,
            processDiskReadClearThreshold: 0,
            processDiskWriteClearThreshold: 0,
            cooldown: cooldown
        )
    }

    @Test("Default thresholds preserve the existing detector values")
    func testDefaultThresholds() {
        let configuration = DetectorConfiguration.standard
        #expect(configuration.cpuThreshold == 80)
        #expect(configuration.memoryThreshold == 90)
        #expect(configuration.diskReadThreshold == 100_000_000)
        #expect(configuration.diskWriteThreshold == 100_000_000)
        #expect(configuration.networkThreshold == 50_000_000)
        #expect(configuration.cooldown == 60)

        let lowProcessThreshold = DetectorConfiguration(
            processDiskReadThreshold: 10_000_000,
            processDiskWriteThreshold: 10_000_000
        )
        #expect(lowProcessThreshold.processDiskReadClearThreshold == 7_000_000)
        #expect(lowProcessThreshold.processDiskWriteClearThreshold == 7_000_000)

        let detector = Detector(configuration: .standard)
        let below = detector.detect(
            snapshot: snapshot(
                cpu: 80,
                memory: 90,
                diskRead: 100_000_000,
                diskWrite: 100_000_000,
                networkIn: 25_000_000,
                networkOut: 25_000_000
            )
        )
        #expect(below.isEmpty)

        let above = detector.detect(
            snapshot: snapshot(
                at: date(1),
                cpu: 81,
                memory: 91,
                diskRead: 100_000_001,
                diskWrite: 100_000_001,
                networkIn: 30_000_000,
                networkOut: 30_000_001
            )
        )
        #expect(above.count == 5)
        #expect(Set(above.map(\.type)) == [
            "CPU_SPIKE",
            "MEMORY_SPIKE",
            "DISK_SPIKE",
            "NETWORK_SPIKE"
        ])
    }

    @Test("CPU lifecycle uses hysteresis cooldown clear and retrigger")
    func testCPULifecycle() {
        let detector = Detector(
            configuration: DetectorConfiguration(
                cpuThreshold: 80,
                memoryThreshold: 1_000,
                diskReadThreshold: 1_000_000_000,
                diskWriteThreshold: 1_000_000_000,
                networkThreshold: 1_000_000_000,
                cpuClearThreshold: 70,
                memoryClearThreshold: 0,
                diskReadClearThreshold: 0,
                diskWriteClearThreshold: 0,
                networkClearThreshold: 0,
                cooldown: 60
            )
        )

        #expect(detector.detect(snapshot: snapshot(at: date(0), cpu: 79)).isEmpty)
        #expect(detector.state(for: .cpu) == .inactive)

        let triggered = detector.detect(
            snapshot: snapshot(at: date(1), cpu: 81)
        )
        #expect(triggered.map(\.type) == ["CPU_SPIKE"])
        #expect(detector.state(for: .cpu) == .triggered)

        #expect(detector.detect(
            snapshot: snapshot(at: date(2), cpu: 79)
        ).isEmpty)
        #expect(detector.state(for: .cpu) == .active)

        #expect(detector.detect(
            snapshot: snapshot(at: date(30), cpu: 81)
        ).isEmpty)
        #expect(detector.detect(
            snapshot: snapshot(at: date(61), cpu: 81)
        ).map(\.type) == ["CPU_SPIKE"])
        #expect(detector.state(for: .cpu) == .active)

        #expect(detector.detect(
            snapshot: snapshot(at: date(62), cpu: 70)
        ).isEmpty)
        #expect(detector.state(for: .cpu) == .cleared)

        #expect(detector.detect(
            snapshot: snapshot(at: date(63), cpu: 81)
        ).map(\.type) == ["CPU_SPIKE"])
        #expect(detector.state(for: .cpu) == .triggered)
    }

    @Test("Memory follows the same hysteresis lifecycle")
    func testMemoryLifecycle() {
        let detector = Detector(
            configuration: DetectorConfiguration(
                cpuThreshold: 1_000,
                memoryThreshold: 90,
                diskReadThreshold: 1_000_000_000,
                diskWriteThreshold: 1_000_000_000,
                networkThreshold: 1_000_000_000,
                cpuClearThreshold: 0,
                memoryClearThreshold: 80,
                diskReadClearThreshold: 0,
                diskWriteClearThreshold: 0,
                networkClearThreshold: 0,
                cooldown: 60
            )
        )

        #expect(detector.detect(snapshot: snapshot(at: date(0), memory: 89)).isEmpty)
        #expect(detector.detect(snapshot: snapshot(at: date(1), memory: 91)).map(\.type) == ["MEMORY_SPIKE"])
        #expect(detector.detect(snapshot: snapshot(at: date(2), memory: 85)).isEmpty)
        #expect(detector.state(for: .memory) == .active)
        #expect(detector.detect(snapshot: snapshot(at: date(3), memory: 80)).isEmpty)
        #expect(detector.state(for: .memory) == .cleared)
        #expect(detector.detect(snapshot: snapshot(at: date(4), memory: 91)).map(\.type) == ["MEMORY_SPIKE"])
    }

    @Test("Network cooldown uses injected time and exact boundary")
    func testNetworkCooldownBoundary() {
        let detector = Detector(
            configuration: configuration(
                network: 50_000_000,
                cooldown: 60
            )
        )

        #expect(detector.detect(
            snapshot: snapshot(at: date(0), networkIn: 51_000_000),
            now: date(0)
        ).map(\.type) == ["NETWORK_SPIKE"])
        #expect(detector.detect(
            snapshot: snapshot(at: date(59), networkIn: 51_000_000),
            now: date(59)
        ).isEmpty)
        #expect(detector.detect(
            snapshot: snapshot(at: date(60), networkIn: 51_000_000),
            now: date(60)
        ).map(\.type) == ["NETWORK_SPIKE"])
        #expect(detector.detect(
            snapshot: snapshot(at: date(1), networkIn: 51_000_000),
            now: date(1)
        ).isEmpty)
    }

    @Test("Global disk read and write have independent identities")
    func testGlobalDiskReadWriteDeduplication() {
        let detector = Detector(
            configuration: configuration(
                diskRead: 100_000_000,
                diskWrite: 100_000_000,
                cooldown: 60
            )
        )

        let first = detector.detect(
            snapshot: snapshot(
                at: date(0),
                diskRead: 101_000_000,
                diskWrite: 102_000_000
            )
        )
        #expect(Set(first.map(\.type)) == ["DISK_SPIKE"])
        #expect(Set(first.map(\.identity)) == [
            "DISK_READ",
            "DISK_WRITE"
        ])

        #expect(detector.detect(
            snapshot: snapshot(
                at: date(1),
                diskRead: 101_000_000,
                diskWrite: 102_000_000
            )
        ).isEmpty)
    }

    @Test("Process disk events contain PID name rates and timestamp")
    func testProcessDiskEvents() throws {
        let detector = Detector(
            configuration: configuration(
                processRead: 100_000_000,
                processWrite: 100_000_000,
                cooldown: 60
            )
        )

        _ = detector.detect(
            snapshot: snapshot(
                at: date(0),
                processes: [process(pid: 42, name: "backup")]
            )
        )

        let events = detector.detect(
            snapshot: snapshot(
                at: date(2),
                processes: [
                    process(
                        pid: 42,
                        name: "backup",
                        readBytes: 220_000_000,
                        writeBytes: 240_000_000
                    )
                ]
            )
        )

        #expect(Set(events.map(\.type)) == [
            "PROCESS_DISK_READ_SPIKE",
            "PROCESS_DISK_WRITE_SPIKE"
        ])
        let readEvent = try #require(events.first {
            $0.type == "PROCESS_DISK_READ_SPIKE"
        })
        let writeEvent = try #require(events.first {
            $0.type == "PROCESS_DISK_WRITE_SPIKE"
        })
        #expect(readEvent.pid == 42)
        #expect(readEvent.processName == "backup")
        #expect(readEvent.readBytesPerSecond == 110_000_000)
        #expect(readEvent.writeBytesPerSecond == 120_000_000)
        #expect(readEvent.timestamp == date(2))
        #expect(readEvent.message.contains("PID 42") == true)
        #expect(writeEvent.value == 120_000_000)
    }

    @Test("Process PID changes and disappearance allow a new event")
    func testProcessPIDChangeAndReturn() {
        let detector = Detector(
            configuration: configuration(
                processRead: 100_000_000,
                processWrite: 1_000_000_000,
                cooldown: 60
            )
        )

        _ = detector.detect(
            snapshot: snapshot(
                at: date(0),
                processes: [process(pid: 1, name: "one")]
            )
        )
        let first = detector.detect(
            snapshot: snapshot(
                at: date(2),
                processes: [process(pid: 1, name: "one", readBytes: 220_000_000)]
            )
        )
        #expect(first.map(\.pid) == [1])

        _ = detector.detect(
            snapshot: snapshot(
                at: date(4),
                processes: [process(pid: 2, name: "two", readBytes: 220_000_000)]
            )
        )
        #expect(detector.state(for: .processDiskRead(pid: 1)) == .cleared)
        _ = detector.detect(
            snapshot: snapshot(
                at: date(6),
                processes: [process(pid: 1, name: "one")]
            )
        )
        let second = detector.detect(
            snapshot: snapshot(
                at: date(8),
                processes: [process(pid: 1, name: "one", readBytes: 220_000_000)]
            )
        )
        #expect(second.map(\.pid) == [1])
        #expect(detector.state(for: .processDiskRead(pid: 1)) == .triggered)
    }

    @Test("Identical active events are deduplicated while different events remain distinct")
    func testDeduplication() {
        let detector = Detector(
            configuration: configuration(
                cpu: 80,
                diskRead: 100_000_000,
                diskWrite: 100_000_000,
                cooldown: 60
            )
        )

        let first = detector.detect(
            snapshot: snapshot(
                at: date(0),
                cpu: 81,
                diskRead: 101_000_000,
                diskWrite: 102_000_000
            )
        )
        #expect(Set(first.map(\.identity)) == [
            "CPU_SPIKE",
            "DISK_READ",
            "DISK_WRITE"
        ])
        #expect(detector.detect(
            snapshot: snapshot(
                at: date(1),
                cpu: 81,
                diskRead: 101_000_000,
                diskWrite: 102_000_000
            )
        ).isEmpty)

        #expect(detector.detect(
            snapshot: snapshot(at: date(2), cpu: 0)
        ).isEmpty)
        #expect(detector.state(for: .cpu) == .cleared)
        #expect(detector.detect(
            snapshot: snapshot(at: date(3), cpu: 81)
        ).map(\.identity) == ["CPU_SPIKE"])
    }

    @Test("Detected event persistence keeps type severity message and snapshot ID")
    func testEventPersistence() throws {
        let path = NSTemporaryDirectory() + "detector_event_\(UUID().uuidString).sqlite"
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + "-wal")
            try? FileManager.default.removeItem(atPath: path + "-shm")
        }

        let database = Database(databasePath: path, logWrites: false)
        let snapshot = snapshot(at: date(0), cpu: 81)
        let snapshotID = try #require(database.save(snapshot: snapshot))
        let detector = Detector(
            configuration: DetectorConfiguration(
                cpuThreshold: 80,
                memoryThreshold: 1_000,
                diskReadThreshold: 1_000_000_000,
                diskWriteThreshold: 1_000_000_000,
                networkThreshold: 1_000_000_000,
                cpuClearThreshold: 70,
                memoryClearThreshold: 0,
                diskReadClearThreshold: 0,
                diskWriteClearThreshold: 0,
                networkClearThreshold: 0,
                cooldown: 60
            )
        )
        let event = try #require(detector.detect(snapshot: snapshot).first)
        database.saveEvent(
            event,
            snapshotID: snapshotID,
            timestamp: snapshot.timestamp
        )

        let persisted = try readPersistedEvent(databasePath: path)
        #expect(persisted.type == event.type)
        #expect(persisted.severity == event.severity)
        #expect(persisted.message == event.message)
        #expect(persisted.snapshotID == snapshotID)
    }

    private func readPersistedEvent(
        databasePath: String
    ) throws -> (type: String, severity: String, message: String, snapshotID: Int64) {
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
                "SELECT type, severity, message, snapshot_id FROM events ORDER BY id LIMIT 1;",
                -1,
                &statement,
                nil
            ) == SQLITE_OK
        )
        defer {
            sqlite3_finalize(statement)
        }

        try #require(sqlite3_step(statement) == SQLITE_ROW)
        let typePointer = try #require(sqlite3_column_text(statement, 0))
        let severityPointer = try #require(sqlite3_column_text(statement, 1))
        let messagePointer = try #require(sqlite3_column_text(statement, 2))
        return (
            String(cString: typePointer),
            String(cString: severityPointer),
            String(cString: messagePointer),
            sqlite3_column_int64(statement, 3)
        )
    }
}

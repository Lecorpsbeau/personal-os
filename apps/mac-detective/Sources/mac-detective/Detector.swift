import Foundation

struct DetectedEvent: Equatable, Sendable {
    let type: String
    let severity: String
    let value: Double
    let message: String
    let identity: String
    let timestamp: Date?
    let pid: Int32?
    let processName: String?
    let readBytesPerSecond: Double?
    let writeBytesPerSecond: Double?

    init(
        type: String,
        severity: String,
        value: Double,
        message: String,
        identity: String? = nil,
        timestamp: Date? = nil,
        pid: Int32? = nil,
        processName: String? = nil,
        readBytesPerSecond: Double? = nil,
        writeBytesPerSecond: Double? = nil
    ) {
        self.type = type
        self.severity = severity
        self.value = value
        self.message = message
        self.identity = identity ?? type
        self.timestamp = timestamp
        self.pid = pid
        self.processName = processName
        self.readBytesPerSecond = readBytesPerSecond
        self.writeBytesPerSecond = writeBytesPerSecond
    }
}

enum DetectorRule: Hashable, Sendable {
    case cpu
    case memory
    case diskRead
    case diskWrite
    case network
    case processDiskRead(pid: Int32)
    case processDiskWrite(pid: Int32)
}

enum DetectorRuleState: String, Equatable, Sendable {
    case inactive
    case triggered
    case active
    case cleared
}

private struct DetectorRuntime {
    var state: DetectorRuleState = .inactive
    var lastEventAt: Date?
}

private struct ProcessDiskRates {
    let readBytesPerSecond: Double
    let writeBytesPerSecond: Double
}

final class Detector {

    let configuration: DetectorConfiguration

    private var runtimes: [DetectorRule: DetectorRuntime] = [:]
    private var lastProcessSampleAt: [Int32: Date] = [:]

    init(configuration: DetectorConfiguration = .standard) {
        self.configuration = configuration
    }

    func detect(snapshot: SystemSnapshot) -> [DetectedEvent] {
        detect(snapshot: snapshot, at: snapshot.timestamp)
    }

    func detect(
        snapshot: SystemSnapshot,
        at date: Date? = nil
    ) -> [DetectedEvent] {
        let now = date ?? snapshot.timestamp
        var events: [DetectedEvent] = []
        var emittedIdentities = Set<String>()

        func append(_ event: DetectedEvent) {
            guard emittedIdentities.insert(event.identity).inserted else {
                return
            }
            events.append(event)
        }

        if updateRule(
            rule: .cpu,
            value: snapshot.cpu,
            trigger: configuration.cpuThreshold,
            clear: configuration.cpuClearThreshold,
            now: now
        ) {
            append(
                DetectedEvent(
                    type: "CPU_SPIKE",
                    severity: "high",
                    value: snapshot.cpu,
                    message: "CPU usage above \(formatNumber(configuration.cpuThreshold))%",
                    timestamp: snapshot.timestamp
                )
            )
        }

        if updateRule(
            rule: .memory,
            value: snapshot.memory,
            trigger: configuration.memoryThreshold,
            clear: configuration.memoryClearThreshold,
            now: now
        ) {
            append(
                DetectedEvent(
                    type: "MEMORY_SPIKE",
                    severity: "high",
                    value: snapshot.memory,
                    message: "Memory usage above \(formatNumber(configuration.memoryThreshold))%",
                    timestamp: snapshot.timestamp
                )
            )
        }

        if updateRule(
            rule: .diskRead,
            value: snapshot.diskRead,
            trigger: configuration.diskReadThreshold,
            clear: configuration.diskReadClearThreshold,
            now: now
        ) {
            append(
                DetectedEvent(
                    type: "DISK_SPIKE",
                    severity: "medium",
                    value: snapshot.diskRead,
                    message: "Disk read above \(formatMegabytesPerSecond(configuration.diskReadThreshold))",
                    identity: "DISK_READ",
                    timestamp: snapshot.timestamp
                )
            )
        }

        if updateRule(
            rule: .diskWrite,
            value: snapshot.diskWrite,
            trigger: configuration.diskWriteThreshold,
            clear: configuration.diskWriteClearThreshold,
            now: now
        ) {
            append(
                DetectedEvent(
                    type: "DISK_SPIKE",
                    severity: "medium",
                    value: snapshot.diskWrite,
                    message: "Disk write above \(formatMegabytesPerSecond(configuration.diskWriteThreshold))",
                    identity: "DISK_WRITE",
                    timestamp: snapshot.timestamp
                )
            )
        }

        let networkTotal = snapshot.networkIn + snapshot.networkOut
        if updateRule(
            rule: .network,
            value: networkTotal,
            trigger: configuration.networkThreshold,
            clear: configuration.networkClearThreshold,
            now: now
        ) {
            append(
                DetectedEvent(
                    type: "NETWORK_SPIKE",
                    severity: "medium",
                    value: networkTotal,
                    message: "Network traffic above \(formatMegabytesPerSecond(configuration.networkThreshold))",
                    timestamp: snapshot.timestamp
                )
            )
        }

        let observedPIDs = Set(snapshot.processes.map(\.pid))
        clearMissingProcessRules(observedPIDs: observedPIDs)
        let processRates = calculateProcessRates(for: snapshot)

        for process in snapshot.processes {
            guard let rates = processRates[process.pid] else {
                continue
            }

            let readRule = DetectorRule.processDiskRead(pid: process.pid)
            if updateRule(
                rule: readRule,
                value: rates.readBytesPerSecond,
                trigger: configuration.processDiskReadThreshold,
                clear: configuration.processDiskReadClearThreshold,
                now: now
            ) {
                append(
                    processEvent(
                        type: "PROCESS_DISK_READ_SPIKE",
                        process: process,
                        rates: rates,
                        timestamp: snapshot.timestamp
                    )
                )
            }

            let writeRule = DetectorRule.processDiskWrite(pid: process.pid)
            if updateRule(
                rule: writeRule,
                value: rates.writeBytesPerSecond,
                trigger: configuration.processDiskWriteThreshold,
                clear: configuration.processDiskWriteClearThreshold,
                now: now
            ) {
                append(
                    processEvent(
                        type: "PROCESS_DISK_WRITE_SPIKE",
                        process: process,
                        rates: rates,
                        timestamp: snapshot.timestamp
                    )
                )
            }
        }

        return events
    }

    func detect(
        snapshot: SystemSnapshot,
        now date: Date
    ) -> [DetectedEvent] {
        detect(snapshot: snapshot, at: date)
    }

    func state(for rule: DetectorRule) -> DetectorRuleState {
        runtimes[rule]?.state ?? .inactive
    }

    func reset() {
        runtimes.removeAll()
        lastProcessSampleAt.removeAll()
    }

    private func updateRule(
        rule: DetectorRule,
        value: Double,
        trigger: Double,
        clear: Double,
        now: Date
    ) -> Bool {
        var runtime = runtimes[rule] ?? DetectorRuntime()
        var shouldEmit = false

        switch runtime.state {
        case .inactive, .cleared:
            if value > trigger {
                runtime.state = .triggered
                shouldEmit = cooldownElapsed(
                    since: runtime.lastEventAt,
                    now: now
                )
                if shouldEmit {
                    runtime.lastEventAt = now
                }
            }

        case .triggered, .active:
            if value > clear {
                if runtime.state == .triggered {
                    runtime.state = .active
                }
                shouldEmit = cooldownElapsed(
                    since: runtime.lastEventAt,
                    now: now
                )
                if shouldEmit {
                    runtime.lastEventAt = now
                }
            } else {
                runtime.state = .cleared
                runtime.lastEventAt = nil
            }
        }

        runtimes[rule] = runtime
        return shouldEmit
    }

    private func cooldownElapsed(
        since lastEventAt: Date?,
        now: Date
    ) -> Bool {
        guard let lastEventAt else {
            return true
        }

        return now.timeIntervalSince(lastEventAt) >= configuration.cooldown
    }

    private func clearMissingProcessRules(observedPIDs: Set<Int32>) {
        let trackedPIDs = Set(
            runtimes.keys.compactMap { rule -> Int32? in
                switch rule {
                case .processDiskRead(let pid), .processDiskWrite(let pid):
                    return pid
                default:
                    return nil
                }
            }
        )

        for pid in trackedPIDs.subtracting(observedPIDs) {
            clearRule(.processDiskRead(pid: pid))
            clearRule(.processDiskWrite(pid: pid))
            lastProcessSampleAt.removeValue(forKey: pid)
        }
    }

    private func clearRule(_ rule: DetectorRule) {
        guard runtimes[rule] != nil else {
            return
        }
        runtimes[rule] = DetectorRuntime(state: .cleared, lastEventAt: nil)
    }

    private func calculateProcessRates(
        for snapshot: SystemSnapshot
    ) -> [Int32: ProcessDiskRates] {
        var uniqueProcesses: [Int32: ProcessSnapshot] = [:]
        for process in snapshot.processes where uniqueProcesses[process.pid] == nil {
            uniqueProcesses[process.pid] = process
        }

        var rates: [Int32: ProcessDiskRates] = [:]
        for (pid, process) in uniqueProcesses {
            let elapsed: TimeInterval
            if let previousDate = lastProcessSampleAt[pid] {
                elapsed = snapshot.timestamp.timeIntervalSince(previousDate)
            } else {
                elapsed = 0
            }

            if elapsed > 0 {
                // ProcessCollector exposes bytes since its previous sample.
                // Divide that observed delta by elapsed time here; collection
                // remains unchanged and the first sample is intentionally a
                // baseline with no derived rate.
                rates[pid] = ProcessDiskRates(
                    readBytesPerSecond: Double(process.diskReadBytes) / elapsed,
                    writeBytesPerSecond: Double(process.diskWriteBytes) / elapsed
                )
                if let previousDate = lastProcessSampleAt[pid] {
                    if snapshot.timestamp >= previousDate {
                        lastProcessSampleAt[pid] = snapshot.timestamp
                    }
                } else {
                    lastProcessSampleAt[pid] = snapshot.timestamp
                }
            } else {
                rates[pid] = ProcessDiskRates(
                    readBytesPerSecond: 0,
                    writeBytesPerSecond: 0
                )
                if lastProcessSampleAt[pid] == nil {
                    lastProcessSampleAt[pid] = snapshot.timestamp
                }
            }
        }

        return rates
    }

    private func processEvent(
        type: String,
        process: ProcessSnapshot,
        rates: ProcessDiskRates,
        timestamp: Date
    ) -> DetectedEvent {
        DetectedEvent(
            type: type,
            severity: "medium",
            value: type == "PROCESS_DISK_READ_SPIKE"
                ? rates.readBytesPerSecond
                : rates.writeBytesPerSecond,
            message: "Process \(process.name) [PID \(process.pid)] " +
                "read \(formatNumber(rates.readBytesPerSecond)) bytes/s, " +
                "write \(formatNumber(rates.writeBytesPerSecond)) bytes/s " +
                "(timestamp \(timestamp.timeIntervalSince1970))",
            identity: "\(type):\(process.pid)",
            timestamp: timestamp,
            pid: process.pid,
            processName: process.name,
            readBytesPerSecond: rates.readBytesPerSecond,
            writeBytesPerSecond: rates.writeBytesPerSecond
        )
    }

    private func formatNumber(_ value: Double) -> String {
        String(format: "%.0f", value)
    }

    private func formatMegabytesPerSecond(_ value: Double) -> String {
        "\(formatNumber(value / 1_000_000)) MB/s"
    }
}

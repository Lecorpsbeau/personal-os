import Foundation
import Darwin
import CProcessRusage

struct ProcessSnapshot {

    let pid: Int32
    let name: String
    let cpuUsage: Double
    let memoryBytes: UInt64
    let diskReadBytes: UInt64
    let diskWriteBytes: UInt64
}

// ProcessCollector is safe to share because sample(), baseline pruning and
// baseline inspection are serialized by the collector lock.
final class ProcessCollector: @unchecked Sendable {

    private let lock = NSLock()
    private var previousCPUTime: [Int32: UInt64] = [:]
    private var previousReadBytes: [Int32: UInt64] = [:]
    private var previousWriteBytes: [Int32: UInt64] = [:]
    private var previousSampleTime: Date?

    func sample() -> [ProcessSnapshot] {
        lock.lock()
        defer { lock.unlock() }

        var processes: [ProcessSnapshot] = []

        guard let pids = listProcessPIDs() else {
            return []
        }

        let now = Date()
        let sampledPIDs = pids.filter { $0 > 0 }
        var observedPIDs = Set<Int32>()

        for pid in sampledPIDs {

            // MARK: - Process information

            var taskInfo = proc_taskinfo()

            let size = Int32(
                MemoryLayout<proc_taskinfo>.size
            )

            let result = proc_pidinfo(
                pid,
                PROC_PIDTASKINFO,
                0,
                &taskInfo,
                size
            )

            guard result == size else {
                continue
            }
            observedPIDs.insert(pid)

            // MARK: - Process name

            var nameBuffer = [CChar](
                repeating: 0,
                count: 256
            )

            let nameLength = proc_name(
                pid,
                &nameBuffer,
                UInt32(nameBuffer.count)
            )

            let name: String

            if nameLength > 0 {
                let nameBytes = nameBuffer
                    .prefix(Int(nameLength))
                    .map { UInt8(bitPattern: $0) }
                name = String(decoding: nameBytes, as: UTF8.self)
            } else {
                name = "Unknown"
            }

            // MARK: - Memory

            let memory = UInt64(
                taskInfo.pti_resident_size
            )

            // MARK: - CPU time

            let cpuTime =
                UInt64(taskInfo.pti_total_user) +
                UInt64(taskInfo.pti_total_system)

            // MARK: - Disk I/O (cumulative lifetime bytes via proc_pid_rusage)
            //
            // get_process_disk_io() wraps proc_pid_rusage(RUSAGE_INFO_V4).
            // It returns 0 on success. Non-zero means the process is gone
            // or we lack permissions — treat as unavailable, not a crash.

            var rawReadBytes: UInt64 = 0
            var rawWriteBytes: UInt64 = 0
            let diskResult = get_process_disk_io(pid, &rawReadBytes, &rawWriteBytes)

            // MARK: - Calculate rates

            var cpuUsage = 0.0
            var diskReadBytes: UInt64 = 0
            var diskWriteBytes: UInt64 = 0

            if let previousTime = previousSampleTime {

                let elapsed =
                    now.timeIntervalSince(previousTime)

                if elapsed > 0 {

                    // CPU

                    if let previousCPU = previousCPUTime[pid] {

                        let cpuDelta =
                            cpuTime >= previousCPU
                            ? cpuTime - previousCPU
                            : 0

                        let cpuSeconds =
                            Double(cpuDelta) /
                            1_000_000_000.0

                        cpuUsage =
                            (cpuSeconds / elapsed) * 100.0
                    }

                    // Disk Read delta (only meaningful if this sample succeeded)

                    if diskResult == 0,
                       let previousRead = previousReadBytes[pid] {
                        diskReadBytes =
                            rawReadBytes >= previousRead
                            ? rawReadBytes - previousRead
                            : 0
                    }

                    // Disk Write delta

                    if diskResult == 0,
                       let previousWrite = previousWriteBytes[pid] {
                        diskWriteBytes =
                            rawWriteBytes >= previousWrite
                            ? rawWriteBytes - previousWrite
                            : 0
                    }
                }
            }

            // MARK: - Save previous values

            previousCPUTime[pid] = cpuTime

            // Only update disk baselines when the call succeeded.
            // Baselines for PIDs that disappear are pruned after sampling.
            if diskResult == 0 {
                previousReadBytes[pid]  = rawReadBytes
                previousWriteBytes[pid] = rawWriteBytes
            }

            // MARK: - Snapshot

            processes.append(
                ProcessSnapshot(
                    pid: pid,
                    name: name.isEmpty
                        ? "Unknown"
                        : name,
                    cpuUsage: cpuUsage,
                    memoryBytes: memory,
                    diskReadBytes: diskReadBytes,
                    diskWriteBytes: diskWriteBytes
                )
            )
        }

        previousSampleTime = now
        pruneBaselinesLocked(keeping: observedPIDs)

        return processes
    }

    private func listProcessPIDs() -> [pid_t]? {
        let initialCount = proc_listallpids(nil, 0)

        guard initialCount > 0 else {
            return nil
        }

        // Leave headroom because processes can be created between the
        // counting call and the filling call. An exact-sized buffer can
        // otherwise be overwritten by proc_listallpids.
        var capacity = max(Int(initialCount) + 64, 64)
        var pids = [pid_t](repeating: 0, count: capacity)
        var count = proc_listallpids(
            &pids,
            Int32(capacity * MemoryLayout<pid_t>.size)
        )

        if Int(count) > capacity {
            capacity = Int(count) + 64
            pids = [pid_t](repeating: 0, count: capacity)
            count = proc_listallpids(
                &pids,
                Int32(capacity * MemoryLayout<pid_t>.size)
            )
        }

        guard count > 0, Int(count) <= capacity else {
            return nil
        }

        return Array(pids.prefix(Int(count)))
    }

    func pruneBaselines(keeping activePIDs: Set<Int32>) {
        lock.lock()
        defer { lock.unlock() }
        pruneBaselinesLocked(keeping: activePIDs)
    }

    private func pruneBaselinesLocked(keeping activePIDs: Set<Int32>) {
        previousCPUTime = previousCPUTime.filter { key, _ in
            activePIDs.contains(key)
        }
        previousReadBytes = previousReadBytes.filter { key, _ in
            activePIDs.contains(key)
        }
        previousWriteBytes = previousWriteBytes.filter { key, _ in
            activePIDs.contains(key)
        }
    }

    var trackedBaselineProcessCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return Set(previousCPUTime.keys)
            .union(previousReadBytes.keys)
            .union(previousWriteBytes.keys)
            .count
    }
}

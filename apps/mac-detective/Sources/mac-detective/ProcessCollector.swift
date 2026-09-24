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

final class ProcessCollector {

    private var previousCPUTime: [Int32: UInt64] = [:]
    private var previousReadBytes: [Int32: UInt64] = [:]
    private var previousWriteBytes: [Int32: UInt64] = [:]
    private var previousSampleTime: Date?

    func sample() -> [ProcessSnapshot] {

        var processes: [ProcessSnapshot] = []

        var count = proc_listallpids(nil, 0)

        guard count > 0 else {
            return []
        }

        var pids = [pid_t](
            repeating: 0,
            count: Int(count)
        )

        count = proc_listallpids(
            &pids,
            Int32(pids.count * MemoryLayout<pid_t>.size)
        )

        guard count > 0 else {
            return []
        }

        let now = Date()

        for pid in pids.prefix(Int(count)) {

            guard pid > 0 else {
                continue
            }

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
                name = String(
                    cString: nameBuffer
                )
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

            // MARK: - Disk I/O
            //
            // Temporarily disabled.
            // proc_pid_rusage caused an unsafe pointer crash
            // on this Swift/macOS SDK combination.
            //
            // We will implement process-level disk I/O
            // through a safer bridge later.
            // MARK: - Disk I/O

            var readBytes: UInt64 = 0
            var writeBytes: UInt64 = 0

         
            if readBytes > 0 || writeBytes > 0 {
                print(
                    "DISK | \(name) | " +
                    "READ \(readBytes) | " +
                    "WRITE \(writeBytes)"
                )
            }

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

                    // Disk Read

                    if let previousRead = previousReadBytes[pid] {

                        diskReadBytes =
                            readBytes >= previousRead
                            ? readBytes - previousRead
                            : 0
                    }

                    // Disk Write

                    if let previousWrite = previousWriteBytes[pid] {

                        diskWriteBytes =
                            writeBytes >= previousWrite
                            ? writeBytes - previousWrite
                            : 0
                    }
                }
            }

            // MARK: - Save previous values

            previousCPUTime[pid] = cpuTime
            previousReadBytes[pid] = readBytes
            previousWriteBytes[pid] = writeBytes

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

        return processes
    }
}

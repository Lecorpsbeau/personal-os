import Foundation

private let sharedCPUCollector = CPUCollector()

// Compatibility façade retained for the existing call site and module API.
func getCPUUsage() -> Double {
    sharedCPUCollector.sample()
}

func getMemoryUsage() -> Double {

    var stats = vm_statistics64()

    var count = mach_msg_type_number_t(
        MemoryLayout<vm_statistics64_data_t>.size /
        MemoryLayout<integer_t>.size
    )

    let result = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(
            to: integer_t.self,
            capacity: Int(count)
        ) {
            host_statistics64(
                mach_host_self(),
                HOST_VM_INFO64,
                $0,
                &count
            )
        }
    }

    guard result == KERN_SUCCESS else {
        return 0
    }

    var pageSize: UInt64 = 0
    var pageSizeSize = MemoryLayout<UInt64>.size

    sysctlbyname(
        "hw.pagesize",
        &pageSize,
        &pageSizeSize,
        nil,
        0
    )

    let active =
        UInt64(stats.active_count) * pageSize

    let wired =
        UInt64(stats.wire_count) * pageSize

    let compressed =
        UInt64(stats.compressor_page_count) * pageSize

    let used = active + wired + compressed

    var totalMemory: UInt64 = 0
    var size = MemoryLayout<UInt64>.size

    sysctlbyname(
        "hw.memsize",
        &totalMemory,
        &size,
        nil,
        0
    )

    guard totalMemory > 0 else {
        return 0
    }

    return Double(used) / Double(totalMemory) * 100
}

@main
struct MacDetective {

    static func main() {

        let database = Database()

        let diskCollector = DiskCollector()
        let networkCollector = NetworkCollector()
        let processCollector = ProcessCollector()
        let detector = Detector()
        let parser = FSUsageParser()
        parser.test()

        let fsUsageCollector = FSUsageCollector(parser: parser)
        fsUsageCollector.start()

        let fsUsageStatus = fsUsageCollector.status
        if fsUsageStatus.permissionDenied {
            print("⚠️ Permissions fs_usage indisponibles : exécution de sudo -n refusée")
            if !fsUsageStatus.stderrMessage.isEmpty {
                print("   \(fsUsageStatus.stderrMessage)")
            }
        } else {
            switch fsUsageStatus.processState {
            case .launchFailed(let message):
                print("❌ fs_usage n'a pas pu démarrer : \(message)")
            case .terminated(let exitCode):
                print("⚠️ fs_usage s'est terminé avec le code \(exitCode)")
            case .outputPipeClosed:
                print("⚠️ Le pipe de sortie fs_usage est fermé")
            case .stopped, .starting, .running:
                break
            }
        }

        print("")
        print("Mac Detective — Monitoring")
        print("--------------------------")
        print("Sampling every 2 seconds")
        print("Press Ctrl+C to stop")
        print("")

        // Initialize delta-based collectors.
        _ = getCPUUsage()
        _ = diskCollector.sample()
        _ = networkCollector.sample()
        _ = processCollector.sample()

        var previousDroppedEventCount = 0
        var lastMaintenanceAt = Date.distantPast

        while true {

            sleep(2)

            let cpu = getCPUUsage()
            let memory = getMemoryUsage()

            let disk = diskCollector.sample()
            let network = networkCollector.sample()
            let processes = processCollector.sample()
            let diskEvents = fsUsageCollector.getBufferedEvents()
            let currentDroppedEventCount = fsUsageCollector.droppedEventCount
            let droppedEvents = max(
                0,
                currentDroppedEventCount - previousDroppedEventCount
            )

            let snapshot = SystemSnapshot(
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

            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "HH:mm:ss"

            print(
                "\(dateFormatter.string(from: snapshot.timestamp)) | " +
                "CPU \(String(format: "%.1f", cpu))% | " +
                "RAM \(String(format: "%.1f", memory))% | " +
                "Disk ↓ \(String(format: "%.1f", disk.readBytesPerSecond / 1_000_000)) MB/s | " +
                "Disk ↑ \(String(format: "%.1f", disk.writeBytesPerSecond / 1_000_000)) MB/s"
            )

            if !diskEvents.isEmpty {
                let totalBytes = diskEvents.reduce(0) { $0 + $1.bytes }
                print("   💾 fs_usage: \(diskEvents.count) disk events (\(String(format: "%.1f", Double(totalBytes) / 1_000_000)) MB)")
            }

            if let snapshotID = database.save(
                snapshot: snapshot,
                diskProcessEvents: diskEvents
            ) {
                previousDroppedEventCount = currentDroppedEventCount
            fsUsageCollector.acknowledgeBufferedEvents(count: diskEvents.count)

            let topDiskProcesses = database.getTopDiskProcesses(snapshotID: snapshotID, limit: 3)
            if !topDiskProcesses.isEmpty {
                print("   💾 Disk activity (fs_usage):")
                for summary in topDiskProcesses {
                    print(
                        "      \(summary.processName) [\(summary.pid)]" +
                        "  ↓ \(String(format: "%.2f", Double(summary.readBytes) / 1_000_000)) MB" +
                        "  ↑ \(String(format: "%.2f", Double(summary.writeBytes) / 1_000_000)) MB"
                    )
                }
            }

            let detectedEvents = detector.detect(snapshot: snapshot)

            for event in detectedEvents {

                print(
                    "⚠️ \(event.type) | " +
                    "\(event.severity) | " +
                    "\(event.message)"
                )

                database.saveEvent(
                    event,
                    snapshotID: snapshotID,
                    timestamp: snapshot.timestamp
                )

                let topProcesses = database.getTopProcesses(
                    snapshotID: snapshotID,
                    limit: 5
                )

                print("   Top processes at this moment:")

                for process in topProcesses {

                    let memoryGB =
                        Double(process.memoryBytes) /
                        1_073_741_824.0

                    print(
                        "   • \(process.name) " +
                        "| CPU \(String(format: "%.1f", process.cpuUsage))% " +
                        "| RAM \(String(format: "%.2f", memoryGB)) GB"
                    )
                }
            }
            }

            let maintenanceDate = Date()
            if maintenanceDate.timeIntervalSince(lastMaintenanceAt) >=
                database.maintenanceInterval {
                do {
                    let report = try database.performMaintenance(
                        now: maintenanceDate
                    )
                    let checkpointed = try database.checkpoint()
                    if !checkpointed {
                        print("⚠️ WAL checkpoint incomplet; il sera repris au prochain cycle")
                    }
                    if report.remainingDirtyBuckets > 0 {
                        print(
                            "ℹ️ Maintenance: \(report.remainingDirtyBuckets) bucket(s) agrégé(s) en attente"
                        )
                    }
                    lastMaintenanceAt = maintenanceDate
                } catch {
                    print("❌ Database maintenance failed: \(error)")
                }
            }
        }
    }
}

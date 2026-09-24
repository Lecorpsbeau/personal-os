import Darwin
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

    let active = UInt64(stats.active_count) * pageSize
    let wired = UInt64(stats.wire_count) * pageSize
    let compressed = UInt64(stats.compressor_page_count) * pageSize

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
        // Install the signal sources before database migration and collector
        // warmup. The router buffers a signal until the runtime is ready.
        let signals = DarwinRuntimeSignalController()
        let signalRouter = RuntimeSignalRouter()
        signals.install { signal in
            signalRouter.receive(signal)
        }

        let fileManager = FileManager.default
        let projectRoot = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let databaseDirectory = projectRoot
            .appendingPathComponent("data/database", isDirectory: true)

        do {
            try fileManager.createDirectory(
                at: databaseDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            print("❌ Impossible de créer le répertoire de données: \(error)")
            signals.cancel()
            Darwin.exit(EXIT_FAILURE)
        }

        let lockPath = databaseDirectory
            .appendingPathComponent(".mac-detective.lock")
            .path
        let instanceLock: SingleInstanceLock
        do {
            instanceLock = try SingleInstanceLock(path: lockPath)
        } catch {
            print("❌ Single-instance: \(error)")
            signals.cancel()
            Darwin.exit(EXIT_FAILURE)
        }

        let configuration = RuntimeConfiguration.standard
        let database = Database(logWrites: false)
        let collector = LiveSnapshotCollector()
        let fsUsage: RuntimeFSUsageSource
        if configuration.fsUsageEnabled {
            let parser = FSUsageParser()
            fsUsage = FSUsageRuntimeSource(
                collector: FSUsageCollector(parser: parser)
            )
        } else {
            fsUsage = DisabledFSUsageRuntimeSource()
        }

        let runtime = MonitoringRuntime(
            configuration: configuration,
            collector: collector,
            fsUsage: fsUsage,
            detection: DetectorRuntimeAdapter(detector: Detector()),
            persistence: DatabaseRuntimePersistence(database: database),
            logger: RuntimeLogger(minimumLevel: configuration.logLevel)
        )

        guard runtime.start() else {
            signals.cancel()
            instanceLock.release()
            Darwin.exit(EXIT_FAILURE)
        }

        signalRouter.connect { _ in
            runtime.requestStop()
        }
        runtime.run()
        signals.cancel()

        // Keep the lock alive until the runtime has fully released resources.
        instanceLock.release()
        if case .failed = runtime.state {
            Darwin.exit(EXIT_FAILURE)
        }
    }
}

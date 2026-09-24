import Foundation

struct DiskProcessEvent {
    let timestamp: Date
    let operation: String
    let bytes: UInt64
    let processName: String
    let pid: Int32
}

final class FSUsageCollector {

    private var process: Process?
    private var pipe: Pipe?

    func start() {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")

        process.arguments = [
            "-n",
            "/usr/bin/fs_usage",
            "-w",
            "-f",
            "diskio"
        ]

        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()

            self.process = process
            self.pipe = pipe

            print("🔍 fs_usage démarré")

            readOutput(pipe: pipe)

        } catch {
            print("❌ Impossible de lancer fs_usage : \(error)")
        }
    }

    private func readOutput(pipe: Pipe) {

        let handle = pipe.fileHandleForReading

        handle.readabilityHandler = { [weak self] handle in

            let data = handle.availableData

            guard !data.isEmpty else {
                return
            }

            guard let output = String(
                data: data,
                encoding: .utf8
            ) else {
                return
            }

            let parser = FSUsageParser()

            for line in output.components(separatedBy: .newlines) {

                guard let event = parser.parse(line) else {
                    continue
                }

                print(
                    "💾 \(event.processName) [\(event.pid)] " +
                    "\(event.operation) \(event.bytes) bytes"
                )
            }
        }
    }

    func stop() {

        pipe?.fileHandleForReading.readabilityHandler = nil

        if let process, process.isRunning {
            process.terminate()
        }

        process = nil
        pipe = nil
    }
}
func test() {
    let sample = """
    21:55:20.636784    PgOut[AP]    D=0x0194580d  B=0x7000   /dev/disk3s6   0.000026 W kernel_task.117
    """

    if let event = parse(sample) {
        print("✅ Parser OK")
        print("   Processus : \(event.processName)")
        print("   PID       : \(event.pid)")
        print("   Opération : \(event.operation)")
        print("   Octets    : \(event.bytes)")
    } else {
        print("❌ Parser FAILED")
    }
}

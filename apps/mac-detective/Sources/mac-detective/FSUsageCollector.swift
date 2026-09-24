import Foundation

struct DiskProcessEvent: Sendable, Equatable {
    let timestamp: Date
    let operation: String
    let bytes: UInt64
    let processName: String
    let pid: Int32
}

final class FSUsageCollector: @unchecked Sendable {

    private var process: Process?
    private var pipe: Pipe?
    private let parser: FSUsageParser
    private let lock = NSLock()
    private var eventBuffer: [DiskProcessEvent] = []
    private let maxBufferSize: Int

    var onEvent: (@Sendable (DiskProcessEvent) -> Void)?

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    init(parser: FSUsageParser = FSUsageParser(), maxBufferSize: Int = 1000) {
        self.parser = parser
        self.maxBufferSize = maxBufferSize
    }

    func start() {
        let process = Process()
        let pipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")

        process.arguments = [
            "-n",
            "/usr/bin/fs_usage",
            "-w",
            "-f",
            "diskio"
        ]

        process.standardOutput = pipe
        process.standardError = errorPipe

        do {
            try process.run()

            lock.lock()
            self.process = process
            self.pipe = pipe
            lock.unlock()

            print("🔍 fs_usage démarré")

            readOutput(pipe: pipe)

        } catch {
            print("❌ Impossible de lancer fs_usage : \(error)")
        }
    }

    func processOutput(_ output: String) {
        for line in output.components(separatedBy: .newlines) {
            guard let event = parser.parse(line) else {
                continue
            }
            record(event: event)
        }
    }

    private func record(event: DiskProcessEvent) {
        var handler: (@Sendable (DiskProcessEvent) -> Void)?

        lock.lock()
        eventBuffer.append(event)
        if eventBuffer.count > maxBufferSize {
            eventBuffer.removeFirst(eventBuffer.count - maxBufferSize)
        }
        handler = onEvent
        lock.unlock()

        handler?(event)
    }

    func drainEvents() -> [DiskProcessEvent] {
        lock.lock()
        defer { lock.unlock() }
        let events = eventBuffer
        eventBuffer.removeAll()
        return events
    }

    func getBufferedEvents() -> [DiskProcessEvent] {
        lock.lock()
        defer { lock.unlock() }
        return eventBuffer
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

            self?.processOutput(output)
        }
    }

    func stop() {
        lock.lock()
        pipe?.fileHandleForReading.readabilityHandler = nil

        if let process, process.isRunning {
            process.terminate()
        }

        self.process = nil
        self.pipe = nil
        lock.unlock()
    }
}
func test() {
    let sample = """
    21:55:20.636784    PgOut[AP]    D=0x0194580d  B=0x7000   /dev/disk3s6   0.000026 W kernel_task.117
    """

    if let event = FSUsageParser().parse(sample) {
        print("Parser OK")
        print("Processus : \(event.processName)")
        print("PID       : \(event.pid)")
        print("Opération : \(event.operation)")
        print("Octets    : \(event.bytes)")
    } else {
        print("❌ Parser FAILED")
    }
}

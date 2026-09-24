import Foundation

struct DiskProcessEvent: Sendable, Equatable {
    let timestamp: Date
    let operation: String
    let bytes: UInt64
    let processName: String
    let pid: Int32
}

enum FSUsageProcessState: Equatable, Sendable {
    case stopped
    case starting
    case running
    case launchFailed(String)
    case terminated(exitCode: Int32)
    case outputPipeClosed
}

struct FSUsageCollectorStatus: Equatable, Sendable {
    let processState: FSUsageProcessState
    let stderrMessage: String
    let permissionDenied: Bool
    let stdoutClosed: Bool
    let stderrClosed: Bool
}

struct FSUsageLaunchConfiguration {
    let executableURL: URL
    let arguments: [String]

    static let fsUsage = FSUsageLaunchConfiguration(
        executableURL: URL(fileURLWithPath: "/usr/bin/sudo"),
        arguments: [
            "-n",
            "/usr/bin/fs_usage",
            "-w",
            "-f",
            "diskio"
        ]
    )
}

final class FSUsageCollector: @unchecked Sendable {

    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private let parser: FSUsageParser
    private let launchConfiguration: FSUsageLaunchConfiguration
    private let lock = NSLock()
    private let outputLock = NSLock()
    private var eventBuffer: [DiskProcessEvent] = []
    private let maxBufferSize: Int
    private var droppedEvents = 0
    private var pendingOutput = Data()
    private var stderrData = Data()
    private var acceptsPipeOutput = true
    private var processState: FSUsageProcessState = .stopped
    private var stdoutClosed = false
    private var stderrClosed = false
    private var eventHandler: (@Sendable (DiskProcessEvent) -> Void)?

    var onEvent: (@Sendable (DiskProcessEvent) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return eventHandler
        }
        set {
            lock.lock()
            eventHandler = newValue
            lock.unlock()
        }
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    var droppedEventCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return droppedEvents
    }

    var status: FSUsageCollectorStatus {
        lock.lock()
        defer { lock.unlock() }

        let message = String(decoding: stderrData, as: UTF8.self)
        return FSUsageCollectorStatus(
            processState: processState,
            stderrMessage: message,
            permissionDenied: Self.isPermissionFailure(message),
            stdoutClosed: stdoutClosed,
            stderrClosed: stderrClosed
        )
    }

    // Internal lifecycle visibility used by tests without exposing pipe
    // handles as part of the production API.
    var hasOpenPipes: Bool {
        lock.lock()
        defer { lock.unlock() }
        return outputPipe != nil || errorPipe != nil
    }

    init(
        parser: FSUsageParser = FSUsageParser(),
        maxBufferSize: Int = 1000,
        launchConfiguration: FSUsageLaunchConfiguration = .fsUsage
    ) {
        self.parser = parser
        self.maxBufferSize = max(1, maxBufferSize)
        self.launchConfiguration = launchConfiguration
    }

    deinit {
        stop()
    }

    func start() {
        outputLock.lock()
        lock.lock()

        if processState == .starting || processState == .running {
            lock.unlock()
            outputLock.unlock()
            return
        }

        processState = .starting
        acceptsPipeOutput = true
        stdoutClosed = false
        stderrClosed = false
        pendingOutput.removeAll(keepingCapacity: true)
        stderrData.removeAll(keepingCapacity: true)
        lock.unlock()

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = launchConfiguration.executableURL
        process.arguments = launchConfiguration.arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { [weak self] terminatedProcess in
            self?.handleProcessTermination(terminatedProcess)
        }

        lock.lock()
        self.process = process
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        lock.unlock()

        readOutput(pipe: outputPipe)
        readError(pipe: errorPipe)

        do {
            try process.run()
        } catch {
            handleLaunchFailure(process: process, error: error)
            outputLock.unlock()
            return
        }

        if process.isRunning {
            lock.lock()
            if self.process === process, processState == .starting {
                processState = .running
            }
            lock.unlock()
            print("🔍 fs_usage démarré")
        } else {
            handleProcessTermination(process)
            let currentStatus = status
            print(
                "⚠️ fs_usage s'est terminé immédiatement (status: \(currentStatus.processState))"
            )
        }

        outputLock.unlock()
    }

    // Existing test/injection API: the supplied string is treated as a
    // complete output payload, including a final line without a newline.
    func processOutput(_ output: String) {
        for line in output.components(separatedBy: .newlines) {
            processLine(line)
        }
    }

    // Actual pipe chunks use this method. It only parses complete lines and
    // keeps an incomplete suffix for the next chunk.
    func processOutputChunk(_ chunk: String) {
        processOutputData(Data(chunk.utf8))
    }

    func finishOutputStream() {
        outputLock.lock()

        lock.lock()
        guard acceptsPipeOutput else {
            lock.unlock()
            outputLock.unlock()
            return
        }
        let remainder = pendingOutput
        pendingOutput.removeAll(keepingCapacity: false)
        if !stdoutClosed {
            stdoutClosed = true
            if processState == .starting || processState == .running {
                processState = .outputPipeClosed
            }
        }
        lock.unlock()
        outputLock.unlock()

        if !remainder.isEmpty,
           let line = String(data: remainder, encoding: .utf8) {
            processLine(line)
        }
    }

    private func processOutputData(_ data: Data) {
        guard !data.isEmpty else {
            return
        }

        outputLock.lock()

        var completeLines: [String] = []

        lock.lock()
        guard acceptsPipeOutput, !stdoutClosed else {
            lock.unlock()
            outputLock.unlock()
            return
        }
        pendingOutput.append(data)
        while let newlineIndex = pendingOutput.firstIndex(of: 0x0A) {
            let lineData = pendingOutput.subdata(
                in: pendingOutput.startIndex..<newlineIndex
            )
            pendingOutput.removeSubrange(
                pendingOutput.startIndex...newlineIndex
            )

            if let line = String(data: lineData, encoding: .utf8) {
                completeLines.append(line)
            }
        }
        lock.unlock()
        outputLock.unlock()

        for line in completeLines {
            processLine(line)
        }
    }

    private func processLine(_ line: String) {
        guard let event = parser.parse(line) else {
            return
        }
        record(event: event)
    }

    private func record(event: DiskProcessEvent) {
        var handler: (@Sendable (DiskProcessEvent) -> Void)?

        lock.lock()
        if eventBuffer.count >= maxBufferSize {
            let overflow = eventBuffer.count - maxBufferSize + 1
            eventBuffer.removeFirst(overflow)
            droppedEvents += overflow
        }
        eventBuffer.append(event)
        handler = eventHandler
        lock.unlock()

        handler?(event)
    }

    func drainEvents() -> [DiskProcessEvent] {
        lock.lock()
        defer { lock.unlock() }
        let events = eventBuffer
        eventBuffer.removeAll(keepingCapacity: true)
        return events
    }

    func getBufferedEvents() -> [DiskProcessEvent] {
        lock.lock()
        defer { lock.unlock() }
        return eventBuffer
    }

    func acknowledgeBufferedEvents(count: Int) {
        guard count > 0 else {
            return
        }

        lock.lock()
        defer { lock.unlock() }
        eventBuffer.removeFirst(min(count, eventBuffer.count))
    }

    private func readOutput(pipe: Pipe) {
        let handle = pipe.fileHandleForReading

        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData

            guard !data.isEmpty else {
                self?.finishOutputStream()
                return
            }

            self?.processOutputData(data)
        }
    }

    private func readError(pipe: Pipe) {
        let handle = pipe.fileHandleForReading

        handle.readabilityHandler = { [weak self] handle in
            guard let self else {
                return
            }

            let data = handle.availableData

            guard !data.isEmpty else {
                self.lock.lock()
                self.stderrClosed = true
                self.lock.unlock()
                return
            }

            self.lock.lock()
            self.stderrData.append(data)
            if self.stderrData.count > 8_192 {
                self.stderrData.removeFirst(self.stderrData.count - 8_192)
            }
            self.lock.unlock()
        }
    }

    private func handleLaunchFailure(process: Process, error: Error) {
        let message = (error as NSError).localizedDescription

        lock.lock()
        let outputPipe = self.outputPipe
        let errorPipe = self.errorPipe
        if self.process === process {
            acceptsPipeOutput = false
            processState = .launchFailed(message)
            self.process = nil
            self.outputPipe = nil
            self.errorPipe = nil
        }
        lock.unlock()

        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe?.fileHandleForReading.closeFile()
        errorPipe?.fileHandleForReading.closeFile()

        print("❌ Impossible de lancer fs_usage : \(message)")
    }

    private func handleProcessTermination(_ terminatedProcess: Process) {
        lock.lock()
        guard self.process === terminatedProcess else {
            lock.unlock()
            return
        }

        if processState != .stopped {
            processState = .terminated(
                exitCode: terminatedProcess.terminationStatus
            )
        }
        lock.unlock()
    }

    func stop() {
        outputLock.lock()

        lock.lock()
        let process = self.process
        let outputPipe = self.outputPipe
        let errorPipe = self.errorPipe
        self.process = nil
        self.outputPipe = nil
        self.errorPipe = nil
        acceptsPipeOutput = false
        pendingOutput.removeAll(keepingCapacity: false)
        stdoutClosed = true
        stderrClosed = true
        if processState != .stopped {
            processState = .stopped
        }
        lock.unlock()

        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        outputLock.unlock()

        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }

        outputPipe?.fileHandleForReading.closeFile()
        errorPipe?.fileHandleForReading.closeFile()
    }

    private static func isPermissionFailure(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("password is required") ||
            normalized.contains("permission denied") ||
            normalized.contains("operation not permitted") ||
            normalized.contains("not permitted") ||
            normalized.contains("requires root") ||
            normalized.contains("sudo:")
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

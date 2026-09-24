import Foundation

enum RuntimeLogLevel: Int, CaseIterable, Comparable, Sendable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    static func < (lhs: RuntimeLogLevel, rhs: RuntimeLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .debug:
            return "DEBUG"
        case .info:
            return "INFO"
        case .warning:
            return "WARNING"
        case .error:
            return "ERROR"
        }
    }
}

struct RuntimeLogContext: Equatable, Sendable {
    var cycle: Int?
    var timestamp: Date?
    var snapshotID: Int64?
    var eventCount: Int?
    var duration: TimeInterval?
    var errorType: String?

    init(
        cycle: Int? = nil,
        timestamp: Date? = nil,
        snapshotID: Int64? = nil,
        eventCount: Int? = nil,
        duration: TimeInterval? = nil,
        errorType: String? = nil
    ) {
        self.cycle = cycle
        self.timestamp = timestamp
        self.snapshotID = snapshotID
        self.eventCount = eventCount
        self.duration = duration
        self.errorType = errorType
    }
}

struct RuntimeLogEntry: Equatable, Sendable {
    let level: RuntimeLogLevel
    let message: String
    let context: RuntimeLogContext
    let timestamp: Date
}

protocol RuntimeLogging: AnyObject {
    func log(
        _ level: RuntimeLogLevel,
        _ message: String,
        context: RuntimeLogContext
    )
}

final class RuntimeLogger: RuntimeLogging {
    let minimumLevel: RuntimeLogLevel
    private let sink: RuntimeLogSink
    private let clock: RuntimeClock

    init(
        minimumLevel: RuntimeLogLevel = .info,
        sink: RuntimeLogSink = StandardRuntimeLogSink(),
        clock: RuntimeClock = SystemRuntimeClock()
    ) {
        self.minimumLevel = minimumLevel
        self.sink = sink
        self.clock = clock
    }

    func log(
        _ level: RuntimeLogLevel,
        _ message: String,
        context: RuntimeLogContext = RuntimeLogContext()
    ) {
        guard level >= minimumLevel else {
            return
        }

        let entryContext: RuntimeLogContext
        if context.timestamp != nil {
            entryContext = context
        } else {
            entryContext = RuntimeLogContext(
                cycle: context.cycle,
                timestamp: clock.now,
                snapshotID: context.snapshotID,
                eventCount: context.eventCount,
                duration: context.duration,
                errorType: context.errorType
            )
        }
        sink.write(
            RuntimeLogEntry(
                level: level,
                message: message,
                context: entryContext,
                timestamp: clock.now
            )
        )
    }

    func debug(
        _ message: String,
        context: RuntimeLogContext = RuntimeLogContext()
    ) {
        log(.debug, message, context: context)
    }

    func info(
        _ message: String,
        context: RuntimeLogContext = RuntimeLogContext()
    ) {
        log(.info, message, context: context)
    }

    func warning(
        _ message: String,
        context: RuntimeLogContext = RuntimeLogContext()
    ) {
        log(.warning, message, context: context)
    }

    func error(
        _ message: String,
        context: RuntimeLogContext = RuntimeLogContext()
    ) {
        log(.error, message, context: context)
    }
}

protocol RuntimeLogSink: AnyObject {
    func write(_ entry: RuntimeLogEntry)
}

final class StandardRuntimeLogSink: RuntimeLogSink {
    func write(_ entry: RuntimeLogEntry) {
        var fields: [String] = []
        if let cycle = entry.context.cycle {
            fields.append("cycle=\(cycle)")
        }
        if let snapshotID = entry.context.snapshotID {
            fields.append("snapshot_id=\(snapshotID)")
        }
        if let eventCount = entry.context.eventCount {
            fields.append("events=\(eventCount)")
        }
        if let duration = entry.context.duration {
            fields.append(String(format: "duration=%.3fs", duration))
        }
        if let errorType = entry.context.errorType {
            fields.append("error_type=\(errorType)")
        }
        let suffix = fields.isEmpty ? "" : " [\(fields.joined(separator: " "))]"
        print("\(entry.timestamp) \(entry.level.label) \(entry.message)\(suffix)")
    }
}

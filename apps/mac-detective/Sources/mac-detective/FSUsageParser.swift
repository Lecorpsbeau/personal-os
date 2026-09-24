import Foundation

final class FSUsageParser {

    private let regex: NSRegularExpression? = {
        let pattern = #"^(\d{2}:\d{2}:\d{2}(?:\.\d+)?)\s+.*?\s+(?:\d+\.\d+\s+)?([A-Za-z]+)\s+(.+?\.\d+)\s*$"#
        return try? NSRegularExpression(pattern: pattern)
    }()

    private let referenceDateProvider: () -> Date
    private let calendar: Calendar

    init(
        referenceDate: @escaping () -> Date = { Date() },
        calendar: Calendar = .current
    ) {
        self.referenceDateProvider = referenceDate
        self.calendar = calendar
    }

    convenience init(
        referenceDate: Date,
        calendar: Calendar = .current
    ) {
        self.init(
            referenceDate: { referenceDate },
            calendar: calendar
        )
    }

    func parse(_ line: String) -> DiskProcessEvent? {
        // Extract non-empty lines to handle multiline string inputs safely.
        let lines = line.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard lines.count == 1, let singleLine = lines.first else {
            return nil
        }

        guard let regex,
              let match = regex.firstMatch(
                  in: singleLine,
                  range: NSRange(singleLine.startIndex..., in: singleLine)
              ),
              match.numberOfRanges >= 4 else {
            return nil
        }

        guard let timeRange = Range(match.range(at: 1), in: singleLine),
              let opRange = Range(match.range(at: 2), in: singleLine),
              let procRange = Range(match.range(at: 3), in: singleLine) else {
            return nil
        }

        let timeString = String(singleLine[timeRange])
        let operation = String(singleLine[opRange])
        let procString = String(singleLine[procRange])

        guard let timestamp = parseTimestamp(timeString) else {
            return nil
        }

        guard let (processName, pid) = parseProcess(procString) else {
            return nil
        }

        guard let bytes = parseBytes(from: singleLine) else {
            return nil
        }

        return DiskProcessEvent(
            timestamp: timestamp,
            operation: operation,
            bytes: bytes,
            processName: processName,
            pid: pid
        )
    }

    private func parseTimestamp(_ string: String) -> Date? {
        let timeParts = string.split(
            separator: ":",
            omittingEmptySubsequences: false
        )

        guard timeParts.count == 3,
              let hour = Int(timeParts[0]),
              (0...23).contains(hour),
              let minute = Int(timeParts[1]),
              (0...59).contains(minute) else {
            return nil
        }

        let secondParts = timeParts[2].split(
            separator: ".",
            omittingEmptySubsequences: false
        )

        guard secondParts.count <= 2,
              let second = Int(secondParts[0]),
              (0...60).contains(second) else {
            return nil
        }

        var nanoseconds = 0

        if secondParts.count == 2 {
            let fraction = secondParts[1]
            guard !fraction.isEmpty,
                  fraction.count <= 9,
                  fraction.allSatisfy({ $0.isNumber }) else {
                return nil
            }

            let normalized = fraction.padding(
                toLength: 9,
                withPad: "0",
                startingAt: 0
            )
            guard let parsedFraction = Int(normalized) else {
                return nil
            }
            nanoseconds = parsedFraction
        }

        let referenceDate = referenceDateProvider()
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = calendar.component(.year, from: referenceDate)
        components.month = calendar.component(.month, from: referenceDate)
        components.day = calendar.component(.day, from: referenceDate)
        components.hour = hour
        components.minute = minute
        components.second = second
        components.nanosecond = nanoseconds

        return calendar.date(from: components)
    }

    private func parseProcess(_ string: String) -> (name: String, pid: Int32)? {
        guard let lastDotIndex = string.lastIndex(of: ".") else {
            return nil
        }

        let namePart = String(string[..<lastDotIndex])
            .trimmingCharacters(in: .whitespaces)
        let pidPart = String(string[string.index(after: lastDotIndex)...])
            .trimmingCharacters(in: .whitespaces)

        guard !namePart.isEmpty,
              let pid = Int32(pidPart),
              pid >= 0 else {
            return nil
        }

        return (namePart, pid)
    }

    private func parseBytes(from line: String) -> UInt64? {
        let components = line.split(whereSeparator: { $0.isWhitespace })

        guard let bytesToken = components.first(where: {
            $0.hasPrefix("B=0x") ||
            $0.hasPrefix("B=0X") ||
            $0.hasPrefix("b=0x") ||
            $0.hasPrefix("b=0X")
        }) else {
            return nil
        }

        let hexBytes = bytesToken.dropFirst(4)
        guard !hexBytes.isEmpty else {
            return nil
        }

        return UInt64(hexBytes, radix: 16)
    }

    func test() {
        let sample = """
        21:55:20.636784    PgOut[AP]    D=0x0194580d  B=0x7000   /dev/disk3s6   0.000026 W kernel_task.117
        """

        if let event = parse(sample) {
            print("Parser OK")
            print("Processus : \(event.processName)")
            print("PID       : \(event.pid)")
            print("Opération : \(event.operation)")
            print("Octets    : \(event.bytes)")
        } else {
            print("❌ Parser FAILED")
        }
    }
}

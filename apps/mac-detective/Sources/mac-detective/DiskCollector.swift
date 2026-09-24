import Foundation
import IOKit
import IOKit.storage

struct DiskActivity {
    let readBytesPerSecond: Double
    let writeBytesPerSecond: Double
}

final class DiskCollector {

    private var previousReadBytes: UInt64 = 0
    private var previousWriteBytes: UInt64 = 0
    private var previousTime: Date?

    func sample() -> DiskActivity {
        let (currentReadBytes, currentWriteBytes) = getDiskCounters()
        let now = Date()

        guard let previousTime else {
            self.previousReadBytes = currentReadBytes
            self.previousWriteBytes = currentWriteBytes
            self.previousTime = now

            return DiskActivity(
                readBytesPerSecond: 0,
                writeBytesPerSecond: 0
            )
        }

        let elapsed = now.timeIntervalSince(previousTime)

        guard elapsed > 0 else {
            return DiskActivity(
                readBytesPerSecond: 0,
                writeBytesPerSecond: 0
            )
        }

        let readDelta = currentReadBytes >= previousReadBytes
            ? currentReadBytes - previousReadBytes
            : 0

        let writeDelta = currentWriteBytes >= previousWriteBytes
            ? currentWriteBytes - previousWriteBytes
            : 0

        self.previousReadBytes = currentReadBytes
        self.previousWriteBytes = currentWriteBytes
        self.previousTime = now

        return DiskActivity(
            readBytesPerSecond: Double(readDelta) / elapsed,
            writeBytesPerSecond: Double(writeDelta) / elapsed
        )
    }

    private func getDiskCounters() -> (UInt64, UInt64) {
        let matching = IOServiceMatching("IOBlockStorageDriver")

        var iterator: io_iterator_t = 0

        let result = IOServiceGetMatchingServices(
            0,
            matching,
            &iterator
        )

        guard result == KERN_SUCCESS else {
            return (0, 0)
        }

        var totalRead: UInt64 = 0
        var totalWrite: UInt64 = 0

        var service = IOIteratorNext(iterator)

        while service != 0 {

            var properties: Unmanaged<CFMutableDictionary>?

            let propertyResult = IORegistryEntryCreateCFProperties(
                service,
                &properties,
                kCFAllocatorDefault,
                0
            )

            if propertyResult == KERN_SUCCESS,
               let properties = properties?.takeRetainedValue()
                    as? [String: Any],
               let statistics = properties["Statistics"] as? [String: Any] {

                if let read = statistics["Bytes (Read)"] as? UInt64 {
                    totalRead += read
                }

                if let write = statistics["Bytes (Write)"] as? UInt64 {
                    totalWrite += write
                }
            }

            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        IOObjectRelease(iterator)

        return (totalRead, totalWrite)
    }
}

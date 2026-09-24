import Foundation
import Darwin

struct NetworkActivity {
    let bytesInPerSecond: Double
    let bytesOutPerSecond: Double
}

final class NetworkCollector {

    private var previousBytesIn: UInt64 = 0
    private var previousBytesOut: UInt64 = 0
    private var previousTime: Date?

    func sample() -> NetworkActivity {
        let (currentIn, currentOut) = getNetworkCounters()
        let now = Date()

        guard let previousTime else {
            self.previousBytesIn = currentIn
            self.previousBytesOut = currentOut
            self.previousTime = now

            return NetworkActivity(
                bytesInPerSecond: 0,
                bytesOutPerSecond: 0
            )
        }

        let elapsed = now.timeIntervalSince(previousTime)

        guard elapsed > 0 else {
            return NetworkActivity(
                bytesInPerSecond: 0,
                bytesOutPerSecond: 0
            )
        }

        let inDelta = currentIn >= previousBytesIn
            ? currentIn - previousBytesIn
            : 0

        let outDelta = currentOut >= previousBytesOut
            ? currentOut - previousBytesOut
            : 0

        self.previousBytesIn = currentIn
        self.previousBytesOut = currentOut
        self.previousTime = now

        return NetworkActivity(
            bytesInPerSecond: Double(inDelta) / elapsed,
            bytesOutPerSecond: Double(outDelta) / elapsed
        )
    }

    private func getNetworkCounters() -> (UInt64, UInt64) {
        var interfaces: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&interfaces) == 0 else {
            return (0, 0)
        }

        defer {
            freeifaddrs(interfaces)
        }

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0

        var current = interfaces

        while let interface = current {
            let address = interface.pointee.ifa_addr

            if let address,
               address.pointee.sa_family == UInt8(AF_LINK),
               let data = interface.pointee.ifa_data {

                let networkData = data
                    .assumingMemoryBound(to: if_data.self)
                    .pointee

                totalIn += UInt64(networkData.ifi_ibytes)
                totalOut += UInt64(networkData.ifi_obytes)
            }

            current = interface.pointee.ifa_next
        }

        return (totalIn, totalOut)
    }
}

import Foundation

struct DetectedEvent {
    let type: String
    let severity: String
    let value: Double
    let message: String
}

final class Detector {

    func detect(snapshot: SystemSnapshot) -> [DetectedEvent] {

        var events: [DetectedEvent] = []

        // CPU
        if snapshot.cpu > 80 {
            events.append(
                DetectedEvent(
                    type: "CPU_SPIKE",
                    severity: "high",
                    value: snapshot.cpu,
                    message: "CPU usage above 80%"
                )
            )
        }

        // RAM
        if snapshot.memory > 90 {
            events.append(
                DetectedEvent(
                    type: "MEMORY_SPIKE",
                    severity: "high",
                    value: snapshot.memory,
                    message: "Memory usage above 90%"
                )
            )
        }

        // Disk Read
        if snapshot.diskRead > 100_000_000 {
            events.append(
                DetectedEvent(
                    type: "DISK_SPIKE",
                    severity: "medium",
                    value: snapshot.diskRead,
                    message: "Disk read above 100 MB/s"
                )
            )
        }

        // Disk Write
        if snapshot.diskWrite > 100_000_000 {
            events.append(
                DetectedEvent(
                    type: "DISK_SPIKE",
                    severity: "medium",
                    value: snapshot.diskWrite,
                    message: "Disk write above 100 MB/s"
                )
            )
        }

        // Network
        let networkTotal =
            snapshot.networkIn +
            snapshot.networkOut

        if networkTotal > 50_000_000 {
            events.append(
                DetectedEvent(
                    type: "NETWORK_SPIKE",
                    severity: "medium",
                    value: networkTotal,
                    message: "Network traffic above 50 MB/s"
                )
            )
        }

        return events
    }
}

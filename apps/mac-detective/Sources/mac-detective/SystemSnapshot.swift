import Foundation

struct SystemSnapshot {

    let timestamp: Date

    let cpu: Double
    let memory: Double

    let diskRead: Double
    let diskWrite: Double

    let networkIn: Double
    let networkOut: Double

    let processes: [ProcessSnapshot]
}

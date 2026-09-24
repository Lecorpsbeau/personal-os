import Foundation
import Testing
@testable import DashboardCore

@Suite("Dashboard Configuration")
struct DashboardConfigurationTests {
    @Test("Default paths are derived from the working directory")
    func testDefaultPaths() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("dashboard-config-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configuration = DashboardRepositoryConfiguration.local(
            environment: [:],
            workingDirectory: root,
            detectService: false
        )

        #expect(
            configuration.databaseURL
                == root.appendingPathComponent("data/database/mac_detective.sqlite")
        )
        #expect(
            configuration.runtimeStatusURL
                == root.appendingPathComponent(
                    "data/database/.mac-detective-runtime-status.json"
                )
        )
    }

    @Test("Database and runtime status overrides remain independent")
    func testEnvironmentOverrides() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("dashboard-config-\(UUID().uuidString)", isDirectory: true)
        let status = root.appendingPathComponent("state/runtime.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let configuration = DashboardRepositoryConfiguration.local(
            environment: [
                "MAC_DETECTIVE_RUNTIME_STATUS": status.path
            ],
            workingDirectory: root,
            detectService: false
        )

        #expect(
            configuration.databaseURL
                == root.appendingPathComponent("data/database/mac_detective.sqlite")
        )
        #expect(configuration.runtimeStatusURL == status)
    }

    @Test("The shared repository root is used when provided")
    func testSharedRootOverride() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("dashboard-root-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configuration = DashboardRepositoryConfiguration.local(
            environment: ["PERSONAL_OS_ROOT": root.path],
            detectService: false
        )
        #expect(
            configuration.databaseURL
                == root.appendingPathComponent("data/database/mac_detective.sqlite")
        )
    }

    @Test("A direct Dashboard launch reuses installed LaunchAgent paths")
    func testInstalledServicePaths() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("dashboard-service-\(UUID().uuidString)", isDirectory: true)
        let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let database = home.appendingPathComponent("data/mac.sqlite")
        let status = home.appendingPathComponent("data/status.json")
        let plist: [String: Any] = [
            "Label": "com.personal-os.mac-detective",
            "EnvironmentVariables": [
                "MAC_DETECTIVE_DATABASE": database.path,
                "MAC_DETECTIVE_RUNTIME_STATUS": status.path
            ]
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: agents.appendingPathComponent("com.personal-os.mac-detective.plist"))

        let configuration = DashboardRepositoryConfiguration.local(
            environment: ["HOME": home.path]
        )

        #expect(configuration.databaseURL == database)
        #expect(configuration.runtimeStatusURL == status)
    }

    @Test("Relative environment paths resolve against the local working directory")
    func testRelativeEnvironmentPaths() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("dashboard-config-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configuration = DashboardRepositoryConfiguration.local(
            environment: [
                "MAC_DETECTIVE_DATABASE": "var/mac.sqlite",
                "MAC_DETECTIVE_RUNTIME_STATUS": "var/status.json"
            ],
            workingDirectory: root,
            detectService: false
        )

        #expect(configuration.databaseURL == root.appendingPathComponent("var/mac.sqlite"))
        #expect(configuration.runtimeStatusURL == root.appendingPathComponent("var/status.json"))
    }
}

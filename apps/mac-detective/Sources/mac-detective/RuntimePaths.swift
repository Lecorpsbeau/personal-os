import Foundation

enum RuntimePaths {
    static func repositoryRoot(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let configuredRoot = environment["PERSONAL_OS_ROOT"] {
            return URL(fileURLWithPath: configuredRoot, isDirectory: true)
        }

        let currentDirectory = URL(
            fileURLWithPath: fileManager.currentDirectoryPath,
            isDirectory: true
        )
        var candidates = [currentDirectory]
        var ancestor = currentDirectory
        for _ in 0..<6 {
            ancestor = ancestor.deletingLastPathComponent()
            candidates.append(ancestor)
        }

        if let executableURL = Bundle.main.executableURL {
            var executableDirectory = executableURL.deletingLastPathComponent()
            for _ in 0..<6 {
                candidates.append(executableDirectory)
                executableDirectory = executableDirectory.deletingLastPathComponent()
            }
        }

        return candidates.first { candidate in
            fileManager.fileExists(
                atPath: candidate
                    .appendingPathComponent("apps/mac-detective", isDirectory: true)
                    .path
            )
        } ?? currentDirectory
    }

    static func defaultDatabaseURL(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let configuredPath = environment["MAC_DETECTIVE_DATABASE"] {
            return URL(fileURLWithPath: configuredPath)
        }
        return repositoryRoot(
            fileManager: fileManager,
            environment: environment
        )
        .appendingPathComponent("data/database", isDirectory: true)
        .appendingPathComponent("mac_detective.sqlite")
    }
}

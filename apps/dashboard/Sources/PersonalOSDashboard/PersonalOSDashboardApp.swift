import SwiftUI
import DashboardCore

@main
struct PersonalOSDashboardApp: App {
    @StateObject private var viewModel: DashboardViewModel

    init() {
        let configuration = DashboardRepositoryConfiguration.local()
        let repository = RetryingSQLiteDashboardRepository(
            configuration: configuration
        )
        _viewModel = StateObject(
            wrappedValue: DashboardViewModel(
                repository: repository,
                databasePath: configuration.databaseURL.path,
                schemaVersion: DashboardRepositoryConfiguration.currentSchemaVersion
            )
        )
    }

    var body: some Scene {
        WindowGroup("Personal OS Dashboard") {
            DashboardView(viewModel: viewModel)
        }
        .windowResizability(.contentSize)
    }
}

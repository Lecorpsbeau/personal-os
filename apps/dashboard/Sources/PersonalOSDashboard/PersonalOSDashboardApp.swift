import SwiftUI
import DashboardCore

@main
struct PersonalOSDashboardApp: App {
    @StateObject private var viewModel: DashboardViewModel

    init() {
        let repository: any DashboardRepository
        do {
            repository = try SQLiteDashboardRepository(
                configuration: .local()
            )
        } catch {
            repository = UnavailableDashboardRepository(
                error: DashboardRepositoryError.invalidData(
                    message: error.localizedDescription
                )
            )
        }
        _viewModel = StateObject(
            wrappedValue: DashboardViewModel(repository: repository)
        )
    }

    var body: some Scene {
        WindowGroup("Personal OS Dashboard") {
            DashboardView(viewModel: viewModel)
        }
        .windowResizability(.contentSize)
    }
}

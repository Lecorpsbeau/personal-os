import Testing
@testable import DashboardCore

@Suite("Dashboard Navigation")
struct DashboardNavigationTests {
    @Test("Navigation exposes the five monitoring sections")
    func testSections() {
        #expect(DashboardSection.allCases.map(\.title) == [
            "Overview",
            "History",
            "Processes",
            "Events",
            "Diagnostics"
        ])
    }
}

import Foundation
import Testing
@testable import DashboardCore

@Suite("Dashboard Value Formatting")
struct DashboardValueFormatterTests {
    @Test("Byte rates are displayed in MB/s without inventing data")
    func testByteRateFormatting() {
        #expect(
            DashboardValueFormatter.metric(2_500_000, unit: "MB/s")
                == "2.50 MB/s"
        )
        #expect(DashboardValueFormatter.metric(nil, unit: "MB/s") == "No data")
    }

    @Test("Percentages retain their native unit")
    func testPercentageFormatting() {
        #expect(DashboardValueFormatter.metric(12.34, unit: "%") == "12.3%")
    }
}

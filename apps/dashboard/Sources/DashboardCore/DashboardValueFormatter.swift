import Foundation

public enum DashboardValueFormatter {
    private static let locale = Locale(identifier: "en_US_POSIX")

    public static func metric(_ value: Double?, unit: String) -> String {
        guard let value else { return "No data" }
        if unit == "%" {
            return String(format: "%.1f%%", locale: locale, value)
        }
        if unit == "MB/s" {
            return String(format: "%.2f MB/s", locale: locale, value / 1_000_000)
        }
        return String(format: "%.2f %@", locale: locale, value, unit)
    }
}

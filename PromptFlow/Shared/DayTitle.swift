import Foundation

/// Section-header text for a calendar day: "Today" / "Yesterday" from the
/// system's relative formatting, otherwise day and month (plus year outside
/// the current year). Localized by the OS. Shared by the script list and the
/// Recordings tab.
enum DayTitle {
    static func string(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) || calendar.isDateInYesterday(day) {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            formatter.doesRelativeDateFormatting = true
            formatter.formattingContext = .beginningOfSentence
            return formatter.string(from: day)
        }
        if calendar.isDate(day, equalTo: Date(), toGranularity: .year) {
            return day.formatted(.dateTime.day().month(.wide))
        }
        return day.formatted(.dateTime.day().month(.wide).year())
    }
}

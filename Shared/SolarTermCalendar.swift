import Foundation

struct SolarTermDayStatus: Sendable {
    let previous: String
    let next: String
    let isTermDay: Bool
    let usesPublishedCalendar: Bool
    var label: String { isTermDay ? previous : previous + "—" + next }
}

enum SolarTermCalendar {
    // Published Hong Kong Observatory Gregorian/Lunar calendar tables.
    // Both Hong Kong and Shanghai use UTC+8. These are dates, not term times.
    // https://www.hko.gov.hk/en/gts/time/calendar/text/files/T2026e.txt
    static let publishedDays: [Int: [Int]] = [
        2025: [5,20,3,18,5,20,4,20,5,21,5,21,7,22,7,23,7,23,8,23,7,22,7,21],
        2026: [5,20,4,18,5,20,5,20,5,21,5,21,7,23,7,23,7,23,8,23,7,22,7,22],
        2027: [5,20,4,19,6,21,5,20,6,21,6,21,7,23,8,23,8,23,8,23,7,22,7,22],
    ]
    private static let names = ["小寒","大寒","立春","雨水","惊蛰","春分","清明","谷雨",
        "立夏","小满","芒种","夏至","小暑","大暑","立秋","处暑","白露","秋分",
        "寒露","霜降","立冬","小雪","大雪","冬至"]

    private struct Event { let date: Date; let name: String; let published: Bool }

    private static func events(in year: Int) -> [Event] {
        let calendar = ShanghaiTime.calendar
        if let days = publishedDays[year], days.count == 24 {
            return days.indices.map { index in
                Event(date: calendar.date(from: DateComponents(year: year, month: index/2+1, day: days[index]))!,
                      name: names[index], published: true)
            }
        }
        // Fallback only for years outside the published table, not for 2025–27.
        // Detect a solar-term crossing within each Shanghai-local calendar day.
        let first = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
        let end = calendar.date(byAdding: .year, value: 1, to: first)!
        var result: [Event] = []
        var day = first
        while day < end {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: day)!
            let before = SolarTermPhase.name(at: day.addingTimeInterval(-1))
            let after = SolarTermPhase.name(at: tomorrow.addingTimeInterval(-1))
            if before != after { result.append(Event(date: day, name: after, published: false)) }
            day = tomorrow
        }
        return result
    }

    static func status(at date: Date) -> SolarTermDayStatus {
        let calendar = ShanghaiTime.calendar
        let today = calendar.startOfDay(for: date)
        let year = calendar.component(.year, from: today)
        let events = ((year-1)...(year+1)).flatMap { Self.events(in: $0) }.sorted { $0.date < $1.date }
        if let current = events.first(where: { $0.date == today }) {
            let next = events.first(where: { $0.date > today })!
            return SolarTermDayStatus(previous: current.name, next: next.name, isTermDay: true,
                                      usesPublishedCalendar: current.published)
        }
        let previous = events.last(where: { $0.date < today })!
        let next = events.first(where: { $0.date > today })!
        return SolarTermDayStatus(previous: previous.name, next: next.name, isTermDay: false,
                                  usesPublishedCalendar: previous.published && next.published)
    }
}

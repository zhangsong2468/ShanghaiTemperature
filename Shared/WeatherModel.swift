import Foundation

enum ForecastPeriod: Int, CaseIterable, Codable, Sendable {
    case week = 7
    case fortnight = 15
    case month = 30

    var title: String { self == .month ? "30天趋势" : "\(rawValue)天预报" }
    var kind: String { "ShanghaiTemperature.\(rawValue)Days" }
}

struct TemperatureDay: Identifiable, Codable, Sendable {
    let index: Int
    let date: Date
    let maximum: Double
    let minimum: Double
    var id: Int { index }
}

enum WeatherStatus: String, Sendable {
    case fresh, cached, stale, unavailable, sample
}

struct WeatherSnapshot: Sendable {
    let period: ForecastPeriod
    let days: [TemperatureDay]
    let status: WeatherStatus
    let fetchedAt: Date?
    var isSample: Bool { status == .sample }

    var footer: String {
        if isSample { return "示例 · 非实时" }
        guard !days.isEmpty, let fetchedAt else { return "等待联网" }
        let prefix = status == .stale ? "旧缓存 · " : status == .cached ? "缓存 · " : "获取 "
        return prefix + ShanghaiTime.timestamp(fetchedAt)
    }

    var availability: String {
        if days.isEmpty { return "暂无有效数据，稍后自动重试" }
        if days.count < period.rawValue { return "旧缓存 · 剩余\(days.count)天" }
        return footer
    }

    // Future timeline entries trim elapsed days even if macOS postpones a reload.
    func projected(at date: Date) -> WeatherSnapshot {
        guard !isSample, let fetchedAt else { return self }
        let age = date.timeIntervalSince(fetchedAt)
        let today = ShanghaiTime.calendar.startOfDay(for: date)
        guard age >= 0, age <= ForecastRecord.maximumCacheAge,
              let first = days.firstIndex(where: { $0.date == today }) else {
            return WeatherSnapshot(period: period, days: [], status: .unavailable, fetchedAt: fetchedAt)
        }
        let remaining = days.dropFirst(first).prefix(period.rawValue).enumerated().map { index, day in
            TemperatureDay(index: index, date: day.date, maximum: day.maximum, minimum: day.minimum)
        }
        let old = status == .stale || age >= ForecastRecord.refreshInterval
            || !ShanghaiTime.calendar.isDate(fetchedAt, inSameDayAs: date)
            || remaining.count < period.rawValue
        return WeatherSnapshot(period: period, days: remaining, status: old ? .stale : status, fetchedAt: fetchedAt)
    }

    var temperatureDomain: ClosedRange<Double> {
        let all = days.flatMap { [$0.minimum, $0.maximum] }
        let lower = floor(((all.min() ?? 0) - 2) / 5) * 5
        let upper = ceil(((all.max() ?? 20) + 2) / 5) * 5
        return lower...max(lower + 10, upper)
    }
}

enum ShanghaiTime {
    static let zone = TimeZone(identifier: "Asia/Shanghai")!
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    static func label(_ date: Date) -> String {
        let parts = calendar.dateComponents([.month, .day], from: date)
        return "\(parts.month ?? 1)/\(parts.day ?? 1)"
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: date)
    }

    static func parseDay(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }

    static func nextMidnight(after date: Date) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))!
    }
}

enum SampleWeather {
    // Frozen sample captured during API validation on 2026-11-16.
    // These values are used only in explicitly marked development/gallery previews.
    static let maximum = [18.2,17.4,15.7,10.9,11.1,13.3,14.3,18.9,15.9,11.7,18.1,18.0,21.2,17.2,14.2]
    static let minimum = [11.8,11.7,6.7,3.3,2.7,2.7,6.5,8.7,6.2,3.5,5.6,8.4,11.9,3.1,1.5]
    static let trendMaximum = [19.0765,17.2490,14.8961,11.2627,11.6176,13.8882,15.5216,18.5863,17.0137,15.8451,15.1745,16.5176,17.1608,17.2824,18.0039,17.9902,17.0020,15.4588,14.7431,14.7961,14.0235,12.8706,13.4627,13.4745,14.0020,13.7647,12.8314,13.3608,13.2118,12.6510]
    static let trendMinimum = [12.3529,11.6843,9.6,3.8667,3.6314,2.4471,6.4392,11.5,10.4059,7.8412,6.2529,6.7157,8.3216,9.3824,10.7137,11.3078,10.7255,9.3216,8.5020,8.6667,7.9784,6.5314,6.6471,6.8863,7.4686,7.2706,6.5588,6.2745,6.2824,6.4]

    static func snapshot(for period: ForecastPeriod) -> WeatherSnapshot {
        let high = period == .month ? trendMaximum : maximum
        let low = period == .month ? trendMinimum : minimum
        let start = ShanghaiTime.calendar.date(from: DateComponents(year: 2026, month: 11, day: 16))!
        let days = (0..<period.rawValue).map { index in
            TemperatureDay(index: index,
                date: ShanghaiTime.calendar.date(byAdding: .day, value: index, to: start)!,
                maximum: high[index], minimum: low[index])
        }
        return WeatherSnapshot(period: period, days: days, status: .sample, fetchedAt: nil)
    }
}

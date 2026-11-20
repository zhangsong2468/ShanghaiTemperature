import SwiftUI
import WidgetKit

struct TemperatureEntry: TimelineEntry {
    let date: Date
    let snapshot: WeatherSnapshot
}

struct TemperatureProvider: TimelineProvider {
    let period: ForecastPeriod

    func placeholder(in context: Context) -> TemperatureEntry {
        TemperatureEntry(date: Date(), snapshot: SampleWeather.snapshot(for: period))
    }

    func getSnapshot(in context: Context, completion: @escaping (TemperatureEntry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        Task {
            let snapshot = await WeatherStore.shared.load(period)
            completion(TemperatureEntry(date: Date(), snapshot: snapshot))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TemperatureEntry>) -> Void) {
        Task {
            let snapshot = await WeatherStore.shared.load(period)
            let now = Date()
            var dates = [now]
            let nextHour = ShanghaiTime.calendar.dateInterval(of: .hour, for: now)!.end
            dates += (0..<49).map { nextHour.addingTimeInterval(Double($0) * 3600) }
            if let fetched = snapshot.fetchedAt {
                dates += [fetched.addingTimeInterval(ForecastRecord.refreshInterval),
                          fetched.addingTimeInterval(ForecastRecord.maximumCacheAge + 1)].filter { $0 > now }
            }
            let entries = Array(Set(dates)).sorted().map {
                TemperatureEntry(date: $0, snapshot: snapshot.projected(at: $0))
            }
            completion(Timeline(entries: entries,
                policy: .after(WeatherStore.nextRefresh(for: snapshot, after: now))))
        }
    }
}

// Each Widget type has a stable configuration when WidgetKit reconstructs it
// with init(). Do not reuse one stateful Widget type for different kinds.
private func temperatureConfiguration(for period: ForecastPeriod) -> some WidgetConfiguration {
    StaticConfiguration(kind: period.kind, provider: TemperatureProvider(period: period)) { entry in
        TemperatureChartView(snapshot: entry.snapshot)
            .containerBackground(for: .widget) { Color.clear }
    }
    // WidgetKit rejects formatted LocalizedStringKey metadata at runtime.
    // Force plain text instead of selecting the string-interpolation overload.
    .configurationDisplayName(Text(verbatim: "上海 · " + period.title))
    .description(Text(verbatim: period == .month ? "上海30天高低温长期趋势，仅供参考。" : "上海每日最高温、最低温曲线，固定摄氏度。"))
    .supportedFamilies([.systemMedium])
    .contentMarginsDisabled()
}

struct ShanghaiWeekWidget: Widget {
    var body: some WidgetConfiguration { temperatureConfiguration(for: .week) }
}

struct ShanghaiFortnightWidget: Widget {
    var body: some WidgetConfiguration { temperatureConfiguration(for: .fortnight) }
}

struct ShanghaiMonthWidget: Widget {
    var body: some WidgetConfiguration { temperatureConfiguration(for: .month) }
}

struct RollingTemperatureEntry: TimelineEntry {
    let date: Date
    let snapshot: RollingTemperatureSnapshot
    let commuteRainCondition: CommuteRainCondition
}

struct RollingTemperatureProvider: TimelineProvider {
    let isHangzhou: Bool

    init(isHangzhou: Bool = false) { self.isHangzhou = isHangzhou }

    private func loadSnapshot() async -> RollingTemperatureSnapshot {
        if isHangzhou { return await WeatherStore.shared.loadHangzhouRollingMonth() }
        return await WeatherStore.shared.loadRollingMonth()
    }

    private func loadCommuteRain() async -> CommuteRainUpdate? {
        guard !isHangzhou else { return nil }
        return await CommuteRainStore.shared.load()
    }

    func placeholder(in context: Context) -> RollingTemperatureEntry {
        let date = Date()
        let start = ShanghaiTime.calendar.date(byAdding: .day, value: -15,
            to: ShanghaiTime.calendar.startOfDay(for: date))!
        // Gallery artwork only. These synthetic curves never appear as live data.
        let days = (0..<30).map { index in
            TemperatureDay(index: index,
                date: ShanghaiTime.calendar.date(byAdding: .day, value: index, to: start)!,
                maximum: SampleWeather.maximum[index % 15], minimum: SampleWeather.minimum[index % 15])
        }
        return RollingTemperatureEntry(date: date,
            snapshot: RollingTemperatureSnapshot(days: days, status: .sample, fetchedAt: nil),
            commuteRainCondition: .unknown)
    }

    func getSnapshot(in context: Context, completion: @escaping (RollingTemperatureEntry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        Task {
            async let temperature = loadSnapshot()
            async let rain = loadCommuteRain()
            let (snapshot, rainUpdate) = await (temperature, rain)
            let now = Date()
            completion(RollingTemperatureEntry(date: now, snapshot: snapshot.projected(at: now),
                commuteRainCondition: rainUpdate?.record?.condition(at: now) ?? .unknown))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RollingTemperatureEntry>) -> Void) {
        Task {
            async let temperature = loadSnapshot()
            async let rain = loadCommuteRain()
            let (snapshot, rainUpdate) = await (temperature, rain)
            let now = Date()
            var dates = [now]
            let nextHour = ShanghaiTime.calendar.dateInterval(of: .hour, for: now)!.end
            dates += (0..<49).map { nextHour.addingTimeInterval(Double($0) * 3600) }
            // Include Shanghai midnight explicitly for the rolling date window.
            dates += [ShanghaiTime.nextMidnight(after: now)]
            if let fetched = snapshot.fetchedAt {
                dates += [fetched.addingTimeInterval(ForecastRecord.refreshInterval),
                          fetched.addingTimeInterval(ForecastRecord.maximumCacheAge + 1)].filter { $0 > now }
            }
            if let fetched = rainUpdate?.record?.fetchedAt {
                let expiry = fetched.addingTimeInterval(CommuteRainRecord.maximumAge)
                if expiry > now { dates.append(expiry) }
            }
            let entries = Array(Set(dates)).sorted().map {
                RollingTemperatureEntry(date: $0, snapshot: snapshot.projected(at: $0),
                    commuteRainCondition: rainUpdate?.record?.condition(at: $0) ?? .unknown)
            }
            let temperatureRefresh = WeatherStore.nextRefresh(for: snapshot, after: now)
            let refresh = rainUpdate.map {
                min(temperatureRefresh, max(now.addingTimeInterval(60), $0.refreshAfter))
            } ?? temperatureRefresh
            completion(Timeline(entries: entries, policy: .after(refresh)))
        }
    }

}

struct ShanghaiRollingMonthWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ShanghaiTemperature.Rolling30Days", provider: RollingTemperatureProvider()) { entry in
            RollingTemperatureChartView(snapshot: entry.snapshot, date: entry.date,
                commuteRainCondition: entry.commuteRainCondition)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName(Text(verbatim: "上海 · 前后30天"))
        .description(Text(verbatim: "过去15天与从今天起15天的最高温、最低温曲线，合计30天，固定摄氏度。"))
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

struct HangzhouRollingMonthWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ShanghaiTemperature.HangzhouRolling30Days",
                            provider: RollingTemperatureProvider(isHangzhou: true)) { entry in
            RollingTemperatureChartView(snapshot: entry.snapshot, date: entry.date, cityName: "杭州")
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName(Text(verbatim: "杭州 · 前后30天"))
        .description(Text(verbatim: "杭州过去15天与今起15天的最高温、最低温曲线，合计30天，固定摄氏度。"))
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

@main
struct ShanghaiTemperatureWidgets: WidgetBundle {
    var body: some Widget {
        ShanghaiWeekWidget()
        ShanghaiFortnightWidget()
        ShanghaiMonthWidget()
        ShanghaiRollingMonthWidget()
        AdditionalTemperatureWidgets().body
    }
}

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

struct FixedTemperatureWidget: Widget {
    let period: ForecastPeriod

    // Widget requires init(); the explicit period initializer is used by the
    // bundle to create the three fixed configurations.
    init() {
        period = .week
    }

    init(period: ForecastPeriod) {
        self.period = period
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: period.kind, provider: TemperatureProvider(period: period)) { entry in
            TemperatureChartView(snapshot: entry.snapshot)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("上海 · \(period.title)")
        .description(period == .month ? "上海30天高低温长期趋势，仅供参考。" : "上海每日最高温、最低温曲线，固定摄氏度。")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

@main
struct ShanghaiTemperatureWidgets: WidgetBundle {
    var body: some Widget {
        FixedTemperatureWidget(period: .week)
        FixedTemperatureWidget(period: .fortnight)
        FixedTemperatureWidget(period: .month)
    }
}

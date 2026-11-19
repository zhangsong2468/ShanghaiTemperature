import SwiftUI
import Charts

enum TemperaturePalette {
    static let maximum = Color(red: 0.91, green: 0.43, blue: 0.29)
    static let minimum = Color(red: 0.24, green: 0.64, blue: 0.86)
}

struct TemperatureChartView: View {
    let snapshot: WeatherSnapshot

    private var tickIndices: [Int] {
        switch snapshot.period {
        case .week: return Array(0..<7)
        case .fortnight: return [0, 3, 6, 9, 12, 14]
        case .month: return [0, 7, 14, 21, 29]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text("上海").fontWeight(.medium)
                Text("· \(snapshot.period.title)").foregroundStyle(.secondary)
                Spacer(minLength: 3)
                Text("°C").foregroundStyle(.secondary)
            }
            .font(.system(size: 12))

            if snapshot.days.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "cloud")
                        .font(.system(size: 20, weight: .light))
                    Text("暂无有效预报").font(.system(size: 12))
                    Text("联网后自动更新").font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
              Chart {
                ForEach(snapshot.days) { day in
                    LineMark(x: .value("日期", day.index), y: .value("气温", day.maximum), series: .value("温度", "最高"))
                        .foregroundStyle(by: .value("温度", "最高"))
                        .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.linear)
                    LineMark(x: .value("日期", day.index), y: .value("气温", day.minimum), series: .value("温度", "最低"))
                        .foregroundStyle(by: .value("温度", "最低"))
                        .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.linear)
                    if snapshot.period == .week {
                        PointMark(x: .value("日期", day.index), y: .value("气温", day.maximum))
                            .foregroundStyle(TemperaturePalette.maximum)
                            .symbolSize(10)
                            .annotation(position: .top, spacing: 3) {
                                Text("\(Int(day.maximum.rounded()))°").font(.system(size: 10)).foregroundStyle(.primary)
                            }
                        PointMark(x: .value("日期", day.index), y: .value("气温", day.minimum))
                            .foregroundStyle(TemperaturePalette.minimum)
                            .symbolSize(10)
                            .annotation(position: .bottom, spacing: 3) {
                                Text("\(Int(day.minimum.rounded()))°").font(.system(size: 10)).foregroundStyle(.primary)
                            }
                    }
                }
            }
            .chartForegroundStyleScale(["最高": TemperaturePalette.maximum, "最低": TemperaturePalette.minimum])
            .chartLegend(.hidden)
            .chartYScale(domain: snapshot.temperatureDomain)
            .chartXScale(domain: 0...(snapshot.period.rawValue - 1), range: .plotDimension(padding: 8))
            .chartXAxis {
                AxisMarks(values: tickIndices) { value in
                    AxisValueLabel {
                        if let index = value.as(Int.self), snapshot.days.indices.contains(index) {
                            Text(ShanghaiTime.label(snapshot.days[index].date)).font(.system(size: 9))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .stride(by: 10)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(.secondary.opacity(0.18))
                    AxisValueLabel().font(.system(size: 9))
                }
            }
            .accessibilityLabel("上海\(snapshot.period.title)，每日最高温与最低温，摄氏度")
            }

            HStack(spacing: 8) {
                legend("最高", color: TemperaturePalette.maximum)
                legend("最低", color: TemperaturePalette.minimum)
                Spacer(minLength: 2)
                Text(snapshot.days.isEmpty || snapshot.days.count == snapshot.period.rawValue
                     ? snapshot.footer : "旧缓存 · \(snapshot.days.count)/\(snapshot.period.rawValue)天")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 9))
            if snapshot.period == .month {
                Text("集合平均 · 长期趋势，仅供参考")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .padding(13)
    }

    private func legend(_ name: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Capsule().fill(color).frame(width: 10, height: 2)
            Text(name).foregroundStyle(.secondary)
        }
        .fixedSize()
    }
}


struct RollingTemperatureChartView: View {
    let snapshot: RollingTemperatureSnapshot
    let date: Date
    let cityName: String

    init(snapshot: RollingTemperatureSnapshot, date: Date, cityName: String = "上海") {
        self.snapshot = snapshot
        self.date = date
        self.cityName = cityName
    }

    private var start: Date {
        ShanghaiTime.calendar.date(byAdding: .day, value: -15,
            to: ShanghaiTime.calendar.startOfDay(for: date))!
    }

    private var domain: ClosedRange<Double> {
        let values = snapshot.days.flatMap { [$0.minimum, $0.maximum] }
        let lower = floor(((values.min() ?? 0) - 2) / 5) * 5
        let upper = ceil(((values.max() ?? 20) + 2) / 5) * 5
        return lower...max(lower + 10, upper)
    }

    private var footer: String {
        if snapshot.status == .sample { return "示例 · 非实时" }
        guard !snapshot.days.isEmpty, let fetchedAt = snapshot.fetchedAt else { return "等待联网" }
        if snapshot.days.count < RollingTemperatureSnapshot.count {
            return "旧缓存 · \(snapshot.days.count)/30天"
        }
        let prefix = snapshot.status == .stale ? "旧缓存 · " : snapshot.status == .cached ? "缓存 · " : "获取 "
        return prefix + ShanghaiTime.timestamp(fetchedAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(verbatim: cityName).fontWeight(.medium)
                Text("· 前后30天").foregroundStyle(.secondary)
                Spacer(minLength: 3)
                Text("°C").foregroundStyle(.secondary)
            }
            .font(.system(size: 12))

            if snapshot.days.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "cloud").font(.system(size: 20, weight: .light))
                    Text("暂无有效温度数据").font(.system(size: 12))
                    Text("联网后自动更新").font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart {
                    RuleMark(x: .value("今天", 15))
                        .foregroundStyle(.secondary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 0.7, dash: [3, 3]))
                        .annotation(position: .top, spacing: 2) {
                            Text("今天").font(.system(size: 8)).foregroundStyle(.secondary)
                        }
                    ForEach(snapshot.days) { day in
                        LineMark(x: .value("日期", day.index), y: .value("气温", day.maximum), series: .value("温度", "最高"))
                            .foregroundStyle(by: .value("温度", "最高"))
                            .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.linear)
                        LineMark(x: .value("日期", day.index), y: .value("气温", day.minimum), series: .value("温度", "最低"))
                            .foregroundStyle(by: .value("温度", "最低"))
                            .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.linear)
                    }
                }
                .chartForegroundStyleScale(["最高": TemperaturePalette.maximum, "最低": TemperaturePalette.minimum])
                .chartLegend(.hidden)
                .chartYScale(domain: domain)
                .chartXScale(domain: 0...29, range: .plotDimension(padding: 8))
                .chartXAxis {
                    AxisMarks(values: [0, 7, 15, 22, 29]) { value in
                        AxisValueLabel {
                            if let index = value.as(Int.self),
                               let day = ShanghaiTime.calendar.date(byAdding: .day, value: index, to: start) {
                                Text(ShanghaiTime.label(day)).font(.system(size: 9))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .stride(by: 10)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(.secondary.opacity(0.18))
                        AxisValueLabel().font(.system(size: 9))
                    }
                }
                .accessibilityLabel(Text(verbatim: cityName + "前后30天，过去15天及今起15天，每日最高温与最低温，摄氏度"))
            }

            HStack(spacing: 8) {
                legend("最高", color: TemperaturePalette.maximum)
                legend("最低", color: TemperaturePalette.minimum)
                Spacer(minLength: 2)
                Text(footer).foregroundStyle(.secondary)
            }
            .font(.system(size: 9))
            Text("过去15天 · 今起15天")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(13)
    }

    private func legend(_ name: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Capsule().fill(color).frame(width: 10, height: 2)
            Text(name).foregroundStyle(.secondary)
        }
        .fixedSize()
    }
}

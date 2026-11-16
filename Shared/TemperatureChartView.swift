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

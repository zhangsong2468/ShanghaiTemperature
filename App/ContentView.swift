import SwiftUI
import WidgetKit
import AppKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var regular: WeatherSnapshot?
    @State private var extended: WeatherSnapshot?
    @State private var refreshing = false
    @State private var useLocalThermal = ThermalSourceSettings.current == .local
    @State private var thermalSettingError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text("上海温度").font(.title3).fontWeight(.medium)
                    Text("v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text("上海 · 摄氏度 · 7 / 15 / 30 天")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            Text("右键点击桌面 → 编辑小组件 → 搜索“上海温度”")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text("关闭这个窗口后，桌面小组件仍由系统管理。")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text("15天数据源：\(regular?.availability ?? "正在获取…")")
                Text("30天数据源：\(extended?.availability ?? "正在获取…")")
            }
            .font(.caption).foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 5)) { _ in
                VStack(alignment: .leading, spacing: 5) {
                    if let status = AircraftRequestStatus.current {
                        Text("飞机查询间隔：" + status.intervalText)
                        Text("下次允许查询：" + status.nextRequestText)
                        if status.nextRequest <= Date() {
                            Text("已到允许查询时间，等待系统调度。")
                        }
                    } else {
                        Text("飞机查询间隔：5 min（300 s）")
                        Text("下次允许查询：等待地图组件首次请求")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("本地计算地图体感", isOn: Binding(
                get: { useLocalThermal },
                set: { enabled in
                    do {
                        try ThermalSourceSettings.save(enabled ? .local : .network)
                        useLocalThermal = enabled
                        thermalSettingError = nil
                        WidgetCenter.shared.reloadTimelines(ofKind: "ShanghaiTemperature.RegionalThermalMap")
                    } catch {
                        thermalSettingError = "设置未保存，请稍后重试。"
                    }
                }))
                .toggleStyle(.switch)
                .font(.callout)
            Text(useLocalThermal
                 ? "地图体感由气温、湿度和风速在本机计算。"
                 : "地图体感使用网络数据；首次使用需准备往年同期数据。")
                .font(.caption).foregroundStyle(.secondary)
            if let thermalSettingError {
                Text(thermalSettingError).font(.caption).foregroundStyle(.secondary)
            }
            Link("数据来源：Open-Meteo · CC BY 4.0", destination: URL(string: "https://open-meteo.com/")!)
                .font(.caption)
        }
        .padding(24)
        .frame(width: 380)
        .background(.ultraThinMaterial)
        .task {
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000) }
                catch { break }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    @MainActor
    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        async let normal = WeatherStore.shared.load(.fortnight)
        async let trend = WeatherStore.shared.load(.month)
        let (normalResult, trendResult) = await (normal, trend)
        regular = normalResult
        extended = trendResult
        if normalResult.status == .fresh || trendResult.status == .fresh {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

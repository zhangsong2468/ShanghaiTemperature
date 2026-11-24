import SwiftUI
import WidgetKit
import AppKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var playback = AircraftPlaybackModel()
    @State private var expanded = false
    @State private var systemSleeping = false
    @StateObject private var mapWindow = AircraftMapWindowReference()
    @State private var thermal: ThermalMapUpdate?
    @State private var loadingThermal = false
    @State private var loadingAircraft = false
    @State private var nextThermal = Date.distantPast
    @State private var nextAircraft = Date.distantPast
    @State private var useLocalThermal = ThermalSourceSettings.current == .local
    @State private var pauseAircraft = AircraftPauseSettings.current.paused
    @State private var settingError: String?

    private let mapSize = CGSize(width: 380, height: 440)

    private var display: ThermalMapDisplay {
        thermal?.projected(at: Date()) ?? ThermalMapDisplay(
            snapshot: nil, date: Date(),
            message: "等待地图数据更新", isReplay: false)
    }

    var body: some View {
        VStack(spacing: 0) {
            ThermalMapView(
                display: display,
                appPresentation: true,
                preparedCanvasSize: mapSize)
                .frame(width: 406, height: 466)
                .overlay {
                    if let image = playback.aircraftImage {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(
                                width: mapSize.width,
                                height: mapSize.height)
                            .allowsHitTesting(false)
                    }
                }

            AircraftHistoryRuler(model: playback)
                .padding(.horizontal, 18)

            HStack(spacing: 8) {
                Text(playback.intervalText ?? "")
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .center)

                Button {
                    expanded.toggle()
                } label: {
                    Text(expanded ? "⚙ 收起" : "⚙ 展开")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.65))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
            .frame(height: 25)
            .padding(.horizontal, 18)

            if expanded {
                configuration
            }
        }
        .frame(width: 406)
        .background(Color(
            .sRGB, red: 0.25, green: 0.25, blue: 0.27, opacity: 1))
        .background(AircraftMapWindowReader(reference: mapWindow))
        .task {
            await playback.refreshHistory()
            while !Task.isCancelled {
                if playback.presentationActive {
                    await playback.refreshHistory()
                }
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { break }
            }
        }
        .task {
            while !Task.isCancelled {
                await refreshThermalIfNeeded()
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { break }
            }
        }
        .task {
            while !Task.isCancelled {
                await refreshAircraftIfNeeded()
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { break }
            }
        }
        .task {
            while !Task.isCancelled {
                let window = mapWindow.window
                playback.presentationActive = !systemSleeping
                    && !NSApplication.shared.isHidden
                    && window?.isVisible == true
                    && window?.isMiniaturized == false
                    && window?.occlusionState.contains(.visible) == true
                do { try await Task.sleep(nanoseconds: 100_000_000) }
                catch { break }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Losing keyboard focus does not hide the map window.
            // The visibility monitor controls playback suspension.
            if phase == .active {
                Task { await playback.refreshHistory() }
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.willSleepNotification)) { _ in
                systemSleeping = true
                playback.presentationActive = false
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didWakeNotification)) { _ in
                systemSleeping = false
        }
        .onDisappear {
            playback.presentationActive = false
            playback.stop()
        }
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider()
            HStack(spacing: 7) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                Text("上海温度")
                Spacer()
                Text(Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String ?? "未知")
                .foregroundStyle(.secondary)
            }

            TimelineView(.periodic(from: .now, by: 5)) { _ in
                VStack(alignment: .leading, spacing: 5) {
                    if !pauseAircraft {
                        HStack {
                            Text("航班信息")
                            Spacer()
                            Text(AircraftRequestStatus.current?.intervalText
                                 ?? "10 min（600 s）")
                        }
                    }
                    Text("下次允许查询：" +
                         (AircraftRequestStatus.current?.nextRequestText
                          ?? "等待首次请求"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.secondary)
            }

            Toggle("暂停飞机更新", isOn: Binding(
                get: { pauseAircraft },
                set: { paused in
                    do {
                        try AircraftPauseSettings.save(paused: paused)
                        pauseAircraft = paused
                        settingError = nil
                        nextAircraft = .distantPast
                        WidgetCenter.shared.reloadTimelines(
                            ofKind: "ShanghaiTemperature.RegionalThermalMap")
                    } catch {
                        settingError = "飞机更新设置未保存，请稍后重试。"
                    }
                }))
                .toggleStyle(.switch)
                .controlSize(.mini)

            Toggle("本地计算地图体感", isOn: Binding(
                get: { useLocalThermal },
                set: { enabled in
                    do {
                        try ThermalSourceSettings.save(
                            enabled ? .local : .network)
                        useLocalThermal = enabled
                        settingError = nil
                        nextThermal = .distantPast
                        WidgetCenter.shared.reloadTimelines(
                            ofKind: "ShanghaiTemperature.RegionalThermalMap")
                    } catch {
                        settingError = "体感设置未保存，请稍后重试。"
                    }
                }))
                .toggleStyle(.switch)
                .controlSize(.mini)

            if let settingError {
                Text(settingError).foregroundStyle(.secondary)
            }
            Link("数据来源：Open-Meteo · CC BY 4.0",
                 destination: URL(string: "https://open-meteo.com/")!)
        }
        .font(.system(size: 10))
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }

    @MainActor
    private func refreshThermalIfNeeded() async {
        guard !loadingThermal,
              !systemSleeping,
              Date() >= nextThermal else { return }
        loadingThermal = true
        defer { loadingThermal = false }
        let result = await RegionalThermalStore.shared.load()
        thermal = result
        nextThermal = max(Date().addingTimeInterval(30), result.refreshAfter)
    }

    @MainActor
    private func refreshAircraftIfNeeded() async {
        guard !loadingAircraft,
              !systemSleeping,
              !AircraftPauseSettings.current.paused,
              Date() >= nextAircraft,
              let bounds = aircraftBounds() else { return }
        loadingAircraft = true
        defer { loadingAircraft = false }
        let result = await AircraftOverlayStore.shared.load(bounds: bounds)
        nextAircraft = max(Date().addingTimeInterval(10), result.refreshAfter)
        await playback.refreshHistory()
    }

    // Match the Canvas and projection used by ThermalMapView exactly.
    private func aircraftBounds() -> AircraftBounds? {
        guard let geometry = try? ThermalMapGeometry.bundled(),
              geometry.bounds.count == 4 else { return nil }
        let b = geometry.bounds
        guard b.allSatisfy(\.isFinite),
              b[0] < b[2], b[1] < b[3],
              b[1] > -85, b[3] < 85 else { return nil }

        func mercator(_ latitude: Double) -> Double {
            log(tan(.pi / 4 + latitude * .pi / 360))
        }
        func latitude(_ value: Double) -> Double {
            (2 * atan(exp(value)) - .pi / 2) * 180 / .pi
        }
        let west = b[0] * .pi / 180
        let east = b[2] * .pi / 180
        let south = mercator(b[1])
        let north = mercator(b[3])
        let width = Double(mapSize.width)
        let height = Double(mapSize.height)
        let scale = min(width * 0.64 / (east - west),
                        (height - 18) / (north - south))
        guard scale.isFinite, scale > 0 else { return nil }
        let x = (west + east) / 2
        let y = (south + north) / 2
        let bounds = AircraftBounds(
            west: max(-180, (x - width / (2 * scale)) * 180 / .pi),
            south: max(-85, latitude(y - height / (2 * scale))),
            east: min(180, (x + width / (2 * scale)) * 180 / .pi),
            north: min(85, latitude(y + height / (2 * scale))))
        return bounds.isValid ? bounds : nil
    }
}


// Track the actual owning window without retaining it or relying on its title.
@MainActor
private final class AircraftMapWindowReference: ObservableObject {
    weak var window: NSWindow?
}

@MainActor
private struct AircraftMapWindowReader: NSViewRepresentable {
    let reference: AircraftMapWindowReference

    final class Probe: NSView {
        var reference: AircraftMapWindowReference?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reference?.window = window
        }
    }

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.reference = reference
        return view
    }

    func updateNSView(_ view: Probe, context: Context) {
        view.reference = reference
        reference.window = view.window
    }
}

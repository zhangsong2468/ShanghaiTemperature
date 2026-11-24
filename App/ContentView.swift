import SwiftUI
import WidgetKit
import AppKit
import Combine

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var playback = AircraftPlaybackModel()
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
                    AircraftPlaybackImage(model: playback)
                        .frame(width: mapSize.width, height: mapSize.height)
                        .allowsHitTesting(false)
                }

            AircraftPlaybackControls(model: playback, expanded: $expanded)

            if expanded {
                configuration
            }
        }
        .frame(width: 406)
        .background(Color(
            .sRGB, red: 0.93, green: 0.94, blue: 0.95, opacity: 1))
        .environment(\.colorScheme, .light)
        .background(AircraftMapWindowReader(reference: mapWindow))
        .task {
            playback.presentationActive = mapWindow.presentable && !systemSleeping
            await playback.refreshHistory()
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 30_000_000_000) }
                catch { break }
                if playback.presentationActive {
                    await playback.refreshHistory()
                }
            }
        }
        .task(id: "\(useLocalThermal)-\(systemSleeping)") {
            guard !systemSleeping else { return }
            while !Task.isCancelled {
                await refreshThermalIfNeeded()
                guard await waitForRefresh(until: nextThermal) else { break }
            }
        }
        .task(id: "\(pauseAircraft)-\(systemSleeping)") {
            guard !systemSleeping, !pauseAircraft else { return }
            while !Task.isCancelled {
                await refreshAircraftIfNeeded()
                guard await waitForRefresh(until: nextAircraft) else { break }
            }
        }
        .onChange(of: mapWindow.presentable) { _, visible in
            playback.presentationActive = visible && !systemSleeping
            if playback.presentationActive {
                Task { await playback.refreshHistory() }
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
                mapWindow.refreshVisibility()
                playback.presentationActive = mapWindow.presentable
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

            TimelineView(.periodic(from: .now, by: 30)) { _ in
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
        guard !Task.isCancelled else { return }
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
        guard !Task.isCancelled else { return }
        nextAircraft = max(Date().addingTimeInterval(30), result.refreshAfter)
        await playback.refreshHistory()
    }

    private func waitForRefresh(until date: Date) async -> Bool {
        let delay = min(3600, max(30, date.timeIntervalSinceNow))
        do {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return !Task.isCancelled
        } catch {
            return false
        }
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


// Only these child views observe playback changes. Dragging the ruler does
// not invalidate the temperature map in ContentView.
private struct AircraftPlaybackImage: View {
    @ObservedObject var model: AircraftPlaybackModel

    var body: some View {
        Group {
            if let image = model.aircraftImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
            }
        }
    }
}

private struct AircraftPlaybackControls: View {
    @ObservedObject var model: AircraftPlaybackModel
    @Binding var expanded: Bool

    var body: some View {
        VStack(spacing: 0) {
            AircraftHistoryRuler(model: model)
                .padding(.horizontal, 18)

            HStack(spacing: 8) {
                Text(model.intervalText ?? "")
                    .font(.system(size: 8))
                    .foregroundStyle(.black.opacity(0.50))
                    .frame(maxWidth: .infinity, alignment: .center)

                Button {
                    expanded.toggle()
                } label: {
                    Text(expanded ? "⚙ 收起" : "⚙ 展开")
                        .font(.system(size: 9))
                        .foregroundStyle(.black.opacity(0.60))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
            .frame(height: 25)
            .padding(.horizontal, 18)
        }
    }
}

// Observe the actual owning window without a polling task or retaining it.
@MainActor
private final class AircraftMapWindowReference: ObservableObject {
    weak var window: NSWindow?
    @Published private(set) var presentable = false
    private var subscriptions = Set<AnyCancellable>()

    func attach(_ next: NSWindow?) {
        if window === next {
            refreshVisibility()
            return
        }
        subscriptions.removeAll()
        window = next
        guard let next else {
            setPresentable(false)
            return
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            center.publisher(for: name, object: next)
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.refreshVisibility()
                    }
                }
                .store(in: &subscriptions)
        }
        for name in [NSApplication.didHideNotification,
                     NSApplication.didUnhideNotification] {
            center.publisher(for: name)
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.refreshVisibility()
                    }
                }
                .store(in: &subscriptions)
        }
        center.publisher(for: NSWindow.willCloseNotification, object: next)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.setPresentable(false)
                }
            }
            .store(in: &subscriptions)
        refreshVisibility()
    }

    func refreshVisibility() {
        setPresentable(!NSApplication.shared.isHidden
            && window?.isVisible == true
            && window?.isMiniaturized == false
            && window?.occlusionState.contains(.visible) == true)
    }

    private func setPresentable(_ value: Bool) {
        if presentable != value { presentable = value }
    }
}

@MainActor
private struct AircraftMapWindowReader: NSViewRepresentable {
    let reference: AircraftMapWindowReference

    final class Probe: NSView {
        var reference: AircraftMapWindowReference?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reference?.attach(window)
        }
    }

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.reference = reference
        return view
    }

    func updateNSView(_ view: Probe, context: Context) {
        view.reference = reference
        reference.attach(view.window)
    }
}

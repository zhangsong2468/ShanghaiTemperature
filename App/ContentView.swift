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
    @State private var thermalDisplay: ThermalMapDisplay?
    @State private var thermalFetchedAt: Date?
    @State private var thermalRenderID = UUID()
    @State private var thermalImage: CGImage?
    @State private var lastPreparedBatchID: UUID?
    @State private var requestStatus: AircraftRequestStatus?
    @State private var loadingThermal = false
    @State private var loadingAircraft = false
    @State private var nextThermal = Date.distantPast
    @State private var nextAircraft = Date.distantPast
    @State private var useLocalThermal = false
    @State private var pauseAircraft = false
    @State private var settingsReady = false
    @State private var savingSetting = false
    @State private var settingError: String?

    private let mapSize = AircraftBounds.appCanvas

    private var thermalMap: some View {
        Group {
            if let thermalImage {
                Image(decorative: thermalImage, scale: mapWindow.backingScale)
                    .resizable()
                    .interpolation(.high)
                    .accessibilityLabel("江浙沪体感温度地图")
            } else {
                Text(thermalDisplay?.message ?? "等待地图数据更新")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 276, height: 314)
    }

    var body: some View {
        VStack(spacing: 0) {
            thermalMap
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
        .frame(width: 276)
        .background(Color(
            .sRGB, red: 0.93, green: 0.94, blue: 0.95, opacity: 1))
        .environment(\.colorScheme, .light)
        .background(AircraftMapWindowReader(reference: mapWindow))
        .task {
            let settings = await AircraftSettingsIO.shared.settings()
            useLocalThermal = settings.0 == .local
            pauseAircraft = settings.1
            settingsReady = true
        }
        .task(id: "\(thermalRenderID)-\(mapWindow.backingScale)") {
            await renderThermalMap()
        }
        .task(id: expanded) {
            guard expanded else { return }
            while !Task.isCancelled {
                requestStatus = await AircraftStore.shared.requestStatus()
                do { try await Task.sleep(nanoseconds: 30_000_000_000) }
                catch { break }
            }
        }
        .task {
            playback.presentationActive = mapWindow.presentable && !systemSleeping
            await playback.refreshHistory()
        }
        .task(id: "\(useLocalThermal)-\(systemSleeping)-\(settingsReady)") {
            guard !systemSleeping, settingsReady else { return }
            while !Task.isCancelled {
                await refreshThermalIfNeeded()
                guard await waitForRefresh(until: nextThermal) else { break }
            }
        }
        .task(id: "\(pauseAircraft)-\(systemSleeping)-\(settingsReady)") {
            guard !systemSleeping, settingsReady else { return }
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

            VStack(alignment: .leading, spacing: 5) {
                if !pauseAircraft {
                    HStack {
                        Text("航班信息")
                        Spacer()
                        Text(requestStatus?.intervalText ?? "10 min（600 s）")
                    }
                }
                Text("下次允许查询：" + (requestStatus?.nextRequestText ?? "读取共享状态"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.secondary)

            Toggle("暂停飞机更新", isOn: Binding(
                get: { pauseAircraft },
                set: { paused in
                    Task {
                        savingSetting = true
                        defer { savingSetting = false }
                        do {
                            try await AircraftSettingsIO.shared.savePause(paused)
                            pauseAircraft = paused
                            settingError = nil
                            nextAircraft = .distantPast
                            WidgetCenter.shared.reloadTimelines(
                                ofKind: "ShanghaiTemperature.RegionalThermalMap")
                        } catch {
                            settingError = "飞机更新设置未保存，请稍后重试。"
                        }
                    }
                }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(!settingsReady || savingSetting)

            Toggle("本地计算地图体感", isOn: Binding(
                get: { useLocalThermal },
                set: { enabled in
                    Task {
                        savingSetting = true
                        defer { savingSetting = false }
                        do {
                            try await AircraftSettingsIO.shared.saveThermal(enabled ? .local : .network)
                            useLocalThermal = enabled
                            settingError = nil
                            nextThermal = .distantPast
                            WidgetCenter.shared.reloadTimelines(
                                ofKind: "ShanghaiTemperature.RegionalThermalMap")
                        } catch {
                            settingError = "体感设置未保存，请稍后重试。"
                        }
                    }
                }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(!settingsReady || savingSetting)

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
        let display = result.projected(at: Date())
        let fetchedAt = result.record?.fetchedAt
        if thermalDisplay == nil || thermalFetchedAt != fetchedAt
            || thermalDisplay?.snapshot?.source != display.snapshot?.source
            || thermalDisplay?.snapshot?.date != display.snapshot?.date
            || (display.snapshot == nil && thermalDisplay?.message != display.message) {
            thermalDisplay = display
            thermalFetchedAt = fetchedAt
            thermalRenderID = UUID()
        }
        nextThermal = max(Date().addingTimeInterval(30), result.refreshAfter)
    }

    @MainActor
    private func refreshAircraftIfNeeded() async {
        guard !loadingAircraft,
              !systemSleeping,
              Date() >= nextAircraft,
              let bounds = AircraftBounds.viewport(canvas: mapSize) else { return }
        loadingAircraft = true
        defer { loadingAircraft = false }
        let result = await AircraftStore.shared.load(bounds: bounds)
        guard !Task.isCancelled else { return }
        // A new batch can be published by WidgetKit while the app is idle.
        // Poll the shared state every 30 seconds without waiting for HTTP eligibility.
        nextAircraft = Date().addingTimeInterval(30)
        if !pauseAircraft, let id = result.record?.batchID, id != lastPreparedBatchID {
            _ = await AircraftOverlayStore.shared.load(bounds: bounds, preparedUpdate: result)
            guard !Task.isCancelled else { return }
            lastPreparedBatchID = id
        }
        if expanded { requestStatus = await AircraftStore.shared.requestStatus() }
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

    @MainActor
    private func renderThermalMap() async {
        guard let display = thermalDisplay else { return }
        let scale = mapWindow.backingScale
        let prepared = await Task.detached(priority: .userInitiated) {
            ThermalMapPrepared.prepare(display)
        }.value
        guard !Task.isCancelled else { return }
        let view = ThermalMapView(display: display, appPresentation: true,
            preparedCanvasSize: mapSize, prepared: prepared)
            .frame(width: 276, height: 314)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: 276, height: 314)
        renderer.scale = scale
        if let image = renderer.cgImage {
            thermalImage = image
        }
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
    @Published private(set) var backingScale: CGFloat = 2
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
                     NSWindow.didDeminiaturizeNotification,
                     NSWindow.didChangeBackingPropertiesNotification] {
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
        if let scale = window?.backingScaleFactor, scale != backingScale {
            backingScale = scale
        }
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

import Foundation
import CoreFoundation

enum ThermalSource: String, Codable, Sendable {
    case network, local
}

enum ThermalSourceSettings {
    // Dedicated, non-sensitive preferences domain. The app has write access;
    // the extension also writes aircraft request status. No App Group/Team ID is invented.
    static let domain = "com.songa.ShanghaiTemperature.ThermalPreferences"
    private static let key = "useLocalApparentTemperature"

    static var current: ThermalSource {
        CFPreferencesAppSynchronize(domain as CFString)
        let enabled = CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? Bool ?? false
        return enabled ? .local : .network
    }

    static func save(_ source: ThermalSource) throws {
        CFPreferencesSetAppValue(key as CFString, source == .local ? kCFBooleanTrue : kCFBooleanFalse,
                                 domain as CFString)
        guard CFPreferencesAppSynchronize(domain as CFString), current == source else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }
}


struct AircraftRequestStatus: Sendable {
    let interval: TimeInterval
    let nextRequest: Date?
    let initializedRoles: Set<String>

    var initializationText: String {
        guard nextRequest != nil else { return "共享目录访问失败" }
        let app = initializedRoles.contains("app")
        let widget = initializedRoles.contains("widget")
        switch (app, widget) {
        case (true, true): return "初始化完成（2/2）"
        case (true, false): return "等待小组件初始化（1/2）"
        case (false, true): return "等待主 App 初始化（1/2）"
        case (false, false): return "等待初始化（0/2）"
        }
    }

    var intervalText: String {
        String(format: "%.0f min（%.0f s）", interval / 60, interval)
    }

    var nextRequestText: String {
        guard let nextRequest else { return "暂不可查询" }
        if nextRequest == .distantPast { return "等待首次请求" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: nextRequest) + "（上海时间）"
    }
}


struct AircraftPauseState: Codable, Equatable {
    var paused = false
    var generation = UUID().uuidString
    var changedAt = Date.distantPast
}

enum AircraftPauseSettings {
    private static let key = "aircraftPauseState"

    static var current: AircraftPauseState {
        CFPreferencesAppSynchronize(ThermalSourceSettings.domain as CFString)
        guard let text = CFPreferencesCopyAppValue(
            key as CFString,
            ThermalSourceSettings.domain as CFString) as? String,
              let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(
                AircraftPauseState.self, from: data) else {
            // Stable default; repeated reads must not change generation.
            return AircraftPauseState(
                paused: false, generation: "initial", changedAt: .distantPast)
        }
        return value
    }

    static func save(paused: Bool) throws {
        let value = AircraftPauseState(
            paused: paused, generation: UUID().uuidString, changedAt: Date())
        let data = try JSONEncoder().encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CFPreferencesSetAppValue(
            key as CFString, text as CFString,
            ThermalSourceSettings.domain as CFString)
        guard CFPreferencesAppSynchronize(
            ThermalSourceSettings.domain as CFString),
              current == value else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    // Cancel an outstanding request when pause/resume changes its generation.
    // HTTP headers already received by the caller are still processed normally.
    static func data(
        for request: URLRequest, session: URLSession
    ) async throws -> (Data, URLResponse) {
        let state = current
        guard !state.paused else { throw CancellationError() }
        let transfer = Task {
            try await session.data(for: request)
        }
        let monitor = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    return
                }
                let latest = current
                if latest.paused || latest.generation != state.generation {
                    transfer.cancel()
                    return
                }
            }
        }
        defer { monitor.cancel() }
        return try await withTaskCancellationHandler {
            try await transfer.value
        } onCancel: {
            transfer.cancel()
        }
    }
}

// Synchronous CFPreferences calls must stay off the App's drawing path.
actor AircraftSettingsIO {
    static let shared = AircraftSettingsIO()

    func settings() -> (ThermalSource, Bool) {
        (ThermalSourceSettings.current, AircraftPauseSettings.current.paused)
    }

    func paused() -> Bool { AircraftPauseSettings.current.paused }
    func savePause(_ paused: Bool) throws { try AircraftPauseSettings.save(paused: paused) }
    func saveThermal(_ source: ThermalSource) throws { try ThermalSourceSettings.save(source) }
}

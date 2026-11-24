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


struct AircraftRequestStatus: Codable {
    let interval: TimeInterval
    let nextRequest: Date
    let updatedAt: Date

    private static let key = "aircraftRequestStatus"

    static func publish(interval: TimeInterval, nextRequest: Date) {
        let status = AircraftRequestStatus(
            interval: interval, nextRequest: nextRequest, updatedAt: Date())
        guard let data = try? JSONEncoder().encode(status),
              let text = String(data: data, encoding: .utf8) else { return }
        CFPreferencesSetAppValue(
            key as CFString, text as CFString,
            ThermalSourceSettings.domain as CFString)
        if !CFPreferencesAppSynchronize(ThermalSourceSettings.domain as CFString) {
            NSLog("Aircraft request status could not be shared")
        }
    }

    static var current: AircraftRequestStatus? {
        CFPreferencesAppSynchronize(ThermalSourceSettings.domain as CFString)
        guard let text = CFPreferencesCopyAppValue(
            key as CFString,
            ThermalSourceSettings.domain as CFString) as? String,
              let data = text.data(using: .utf8),
              let status = try? JSONDecoder().decode(Self.self, from: data),
              status.interval.isFinite, status.interval > 0 else { return nil }
        return status
    }

    var intervalText: String {
        String(format: "%.0f min（%.0f s）", interval / 60, interval)
    }

    var nextRequestText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: nextRequest) + "（上海时间）"
    }
}

import Foundation
import CoreFoundation

enum ThermalSource: String, Codable, Sendable {
    case network, local
}

enum ThermalSourceSettings {
    // Dedicated, non-sensitive preferences domain. The app has write access;
    // the extension has read-only access. No false App Group/Team ID is invented.
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

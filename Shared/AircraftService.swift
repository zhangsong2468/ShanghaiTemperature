import Foundation
import CoreFoundation
import OSLog

struct AircraftBounds: Codable, Equatable, Sendable {
    let west: Double
    let south: Double
    let east: Double
    let north: Double

    var isValid: Bool {
        [west, south, east, north].allSatisfy(\.isFinite)
            && west >= -180 && east <= 180 && west < east
            && south >= -85 && north <= 85 && south < north
    }

    // A fixed acquisition region covers the App and standard large widget.
    static let acquisition = AircraftBounds(west: 110, south: 26, east: 129, north: 36)

    static let appCanvas = CGSize(width: 250, height: 288)

    static func viewport(canvas: CGSize) -> AircraftBounds? {
        guard let geometry = try? ThermalMapGeometry.bundled(),
              canvas.width.isFinite, canvas.height.isFinite,
              canvas.width > 0, canvas.height > 18 else { return nil }
        let b = geometry.bounds
        guard b.count == 4, b.allSatisfy(\.isFinite),
              b[0] < b[2], b[1] < b[3], b[1] > -85, b[3] < 85 else { return nil }
        func mercator(_ latitude: Double) -> Double {
            log(tan(.pi / 4 + latitude * .pi / 360))
        }
        func latitude(_ value: Double) -> Double {
            (2 * atan(exp(value)) - .pi / 2) * 180 / .pi
        }
        let west = b[0] * .pi / 180, east = b[2] * .pi / 180
        let south = mercator(b[1]), north = mercator(b[3])
        let width = Double(canvas.width), height = Double(canvas.height)
        let scale = min(width * 0.64 / (east - west), (height - 18) / (north - south))
        guard scale.isFinite, scale > 0 else { return nil }
        let x = (west + east) / 2, y = (south + north) / 2
        let result = AircraftBounds(
            west: max(-180, (x - width / (2 * scale)) * 180 / .pi),
            south: max(-85, latitude(y - height / (2 * scale))),
            east: min(180, (x + width / (2 * scale)) * 180 / .pi),
            north: min(85, latitude(y + height / (2 * scale))))
        return result.isValid ? result : nil
    }

    func contains(longitude: Double, latitude: Double) -> Bool {
        longitude >= west && longitude <= east && latitude >= south && latitude <= north
    }
}

struct AircraftState: Codable, Sendable {
    let icao24: String
    let callsign: String?
    let positionAt: Date
    let longitude: Double
    let latitude: Double
    let track: Double?
    let category: Int

    func isVisible(at now: Date, bounds: AircraftBounds) -> Bool {
        let age = now.timeIntervalSince(positionAt)
        return age >= 0 && age < 600
            && longitude.isFinite && latitude.isFinite
            && bounds.contains(longitude: longitude, latitude: latitude)
    }
}

enum AircraftDisplayPolicy {
    static func choose(
        _ states: [AircraftState],
        at now: Date,
        bounds: AircraftBounds
    ) -> [AircraftState] {
        var unique: [String: AircraftState] = [:]
        for state in states where state.isVisible(at: now, bounds: bounds) {
            if let previous = unique[state.icao24],
               previous.positionAt >= state.positionAt { continue }
            unique[state.icao24] = state
        }
        // All positions younger than ten minutes are eligible.
        // AircraftSelector applies the final ten-aircraft limit.
        return unique.values.sorted { $0.icao24 < $1.icao24 }
    }
}

struct AircraftRecord: Codable, Sendable {
    let schema: Int
    let bounds: AircraftBounds
    let fetchedAt: Date
    let states: [AircraftState]
    var batchID: UUID? = nil

    func scoped(to bounds: AircraftBounds, at date: Date) -> AircraftRecord {
        AircraftRecord(schema: schema, bounds: bounds, fetchedAt: fetchedAt,
            states: AircraftDisplayPolicy.choose(states, at: date, bounds: bounds),
            batchID: batchID)
    }

    func visible(at now: Date) -> [AircraftState] {
        guard schema == 1, bounds.isValid, now >= fetchedAt else { return [] }
        return AircraftDisplayPolicy.choose(states, at: now, bounds: bounds)
    }
}

struct AircraftUpdate: Sendable {
    let record: AircraftRecord?
    let refreshAfter: Date
    let remainingCredits: Int?
}

enum AircraftServiceError: Error {
    case invalidResponse
}

enum AircraftDecoder {
    static func url(bounds: AircraftBounds) throws -> URL {
        guard bounds.isValid else { throw AircraftServiceError.invalidResponse }
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "opensky-network.org"
        parts.path = "/api/states/all"
        parts.queryItems = [
            URLQueryItem(name: "lamin", value: String(bounds.south)),
            URLQueryItem(name: "lomin", value: String(bounds.west)),
            URLQueryItem(name: "lamax", value: String(bounds.north)),
            URLQueryItem(name: "lomax", value: String(bounds.east)),
            URLQueryItem(name: "extended", value: "1")
        ]
        guard let url = parts.url else { throw AircraftServiceError.invalidResponse }
        return url
    }

    static func decode(_ data: Data, bounds: AircraftBounds, now: Date) throws -> AircraftRecord {
        guard bounds.isValid,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timestamp = number(root["time"]),
              timestamp > 0, timestamp <= now.timeIntervalSince1970 + 30,
              let rawStates = root["states"] else { throw AircraftServiceError.invalidResponse }
        let rows: [[Any]]
        if rawStates is NSNull { rows = [] }
        else if let values = rawStates as? [[Any]] { rows = values }
        else { throw AircraftServiceError.invalidResponse }
        var byID: [String: AircraftState] = [:]
        for row in rows {
            guard row.count >= 17,
                  let rawID = row[0] as? String,
                  rawID.range(of: "^[0-9a-fA-F]{6}$", options: .regularExpression) != nil,
                  let position = number(row[3]), position > 0, position <= timestamp,
                  let longitude = number(row[5]), let latitude = number(row[6]),
                  let grounded = row[8] as? NSNumber,
                  CFGetTypeID(grounded) == CFBooleanGetTypeID(), !grounded.boolValue else { continue }
            let heading = number(row[10]).flatMap { (0..<360).contains($0) ? $0 : nil }
            let rawCategory = row.count > 17 ? number(row[17]) : nil
            let category = rawCategory.flatMap { value -> Int? in
                guard value >= 0, value <= 20, value.rounded() == value else { return nil }
                return Int(value)
            } ?? 0
            let call = (row[1] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let state = AircraftState(icao24: rawID.lowercased(),
                callsign: call.flatMap { $0.isEmpty ? nil : $0 },
                positionAt: Date(timeIntervalSince1970: position),
                longitude: longitude, latitude: latitude, track: heading, category: category)
            guard state.isVisible(at: now, bounds: bounds) else { continue }
            if let previous = byID[state.icao24],
               previous.positionAt >= state.positionAt {
                continue
            }
            byID[state.icao24] = state
        }
        return AircraftRecord(schema: 1, bounds: bounds, fetchedAt: now,
            states: byID.values.sorted { $0.icao24 < $1.icao24 })
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
}

// All participants coordinate the same stable directory. The accessor covers
// only local reads and atomic writes; no HTTP request runs inside it.
struct AircraftSharedState: Codable, Sendable {
    struct Batch: Codable, Sendable {
        let id: UUID
        let fetchedAt: Date
    }

    var schema = 1
    var nextAllowedAt = Date.distantPast
    var latestRequestID: UUID?
    var batches: [Batch] = []
    var migratedRoles: Set<String> = []
    var remainingCredits: Int?
}

struct AircraftSharedFiles: Sendable {
    static let path = "Library/Application Support/ShanghaiTemperature-Aircraft-v2"
    static let retention: TimeInterval = 8 * 86400
    static var role: String {
        Bundle.main.bundleIdentifier == "com.songa.ShanghaiTemperature.Widgets" ? "widget" : "app"
    }
    let directory: URL?

    init(directory: URL? = nil) {
        // The sandbox's applicationSupportDirectory differs in both processes.
        // Resolve the real user home; the entitlement grants this one directory.
        if let directory {
            self.directory = directory
        } else if let home = NSHomeDirectoryForUser(NSUserName()) {
            self.directory = URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(Self.path, isDirectory: true)
        } else {
            self.directory = nil
        }
    }

    private func stateURL(_ root: URL) -> URL {
        root.appendingPathComponent("request-state.json")
    }

    static func readIfPresent<T: Decodable>(_ type: T.Type, at url: URL) throws -> T? {
        do {
            return try JSONDecoder().decode(type, from: Data(contentsOf: url))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) {
            return nil
        }
    }

    private func coordinated<T>(_ body: (URL) throws -> T) throws -> T {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var error: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: directory, options: [], error: &error) { url in
            result = Result { try body(url) }
        }
        if let error { throw error }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return try result.get()
    }

    private func readState(_ root: URL) throws -> AircraftSharedState {
        let state = try Self.readIfPresent(AircraftSharedState.self, at: stateURL(root))
            ?? AircraftSharedState()
        guard state.schema == 1, state.nextAllowedAt.timeIntervalSinceReferenceDate.isFinite,
              state.batches.allSatisfy({ $0.fetchedAt.timeIntervalSinceReferenceDate.isFinite }),
              Set(state.batches.map(\.id)).count == state.batches.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return state
    }

    private func writeState(_ state: AircraftSharedState, at root: URL) throws {
        try JSONEncoder().encode(state).write(to: stateURL(root), options: .atomic)
    }

    func snapshot() throws -> AircraftSharedState {
        try coordinated { try readState($0) }
    }

    func claim(role: String, legacyDeadline: () throws -> Date,
               interval: TimeInterval, floor: Date, paused: Bool,
               now: Date? = nil) throws -> (AircraftSharedState, UUID?) {
        try coordinated { root in
            var state = try readState(root)
            var changed = false
            if !state.migratedRoles.contains(role) {
                state.nextAllowedAt = max(state.nextAllowedAt, try legacyDeadline())
                state.migratedRoles.insert(role)
                changed = true
            }
            if floor > state.nextAllowedAt {
                state.nextAllowedAt = floor
                changed = true
            }
            let claimTime = now ?? Date()
            var id: UUID? = nil
            // Both legacy containers must be migrated before a network request.
            if !paused, state.migratedRoles.isSuperset(of: ["app", "widget"]),
               claimTime >= state.nextAllowedAt {
                guard interval.isFinite, interval >= 600 else { throw CocoaError(.fileWriteUnknown) }
                id = UUID()
                state.latestRequestID = id
                state.nextAllowedAt = claimTime.addingTimeInterval(interval)
                changed = true
            }
            if changed { try writeState(state, at: root) }
            return (state, id)
        }
    }

    func applyResponse(id: UUID, deadline: Date, credits: Int?) throws -> AircraftSharedState {
        try coordinated { root in
            var state = try readState(root)
            state.nextAllowedAt = max(state.nextAllowedAt, deadline)
            if state.latestRequestID == id { state.remainingCredits = credits }
            try writeState(state, at: root)
            return state
        }
    }

    func publish(_ record: AircraftRecord, id: UUID) throws -> AircraftSharedState {
        try coordinated { root in
            var state = try readState(root)
            guard state.latestRequestID == id, record.batchID == id else { return state }
            // The immutable batch is written first; it is visible only after the
            // state manifest is replaced. Retries with this ID are idempotent.
            if state.batches.contains(where: { $0.id == id }) { return state }
            try JSONEncoder().encode(record).write(
                to: root.appendingPathComponent("aircraft-\(id.uuidString).json"), options: .atomic)
            let cutoff = record.fetchedAt.addingTimeInterval(-Self.retention)
            let expired = state.batches.filter { $0.fetchedAt < cutoff }
            state.batches.removeAll { $0.fetchedAt < cutoff }
            state.batches.append(.init(id: id, fetchedAt: record.fetchedAt))
            try writeState(state, at: root)
            for batch in expired {
                try? FileManager.default.removeItem(
                    at: root.appendingPathComponent("aircraft-\(batch.id.uuidString).json"))
                for role in ["app", "widget"] {
                    try? FileManager.default.removeItem(
                        at: root.appendingPathComponent("presentation-\(batch.id.uuidString)-\(role).json"))
                }
            }
            return state
        }
    }

    func record(for batch: AircraftSharedState.Batch) throws -> AircraftRecord? {
        guard let directory else { return nil }
        guard let record = try Self.readIfPresent(AircraftRecord.self,
            at: directory.appendingPathComponent("aircraft-\(batch.id.uuidString).json")),
            record.schema == 1, record.batchID == batch.id,
            record.fetchedAt == batch.fetchedAt, record.bounds == .acquisition else { return nil }
        return record
    }

    func presentationURL(_ id: UUID, role: String) -> URL? {
        directory?.appendingPathComponent("presentation-\(id.uuidString)-\(role).json")
    }
}

actor AircraftStore {
    static let shared = AircraftStore()
    private let legacyDirectory: URL
    private let files: AircraftSharedFiles
    private let session: URLSession
    private let refreshInterval: TimeInterval
    private var record: AircraftRecord?
    private var floor: Date = .distantPast
    private var inFlight: Task<AircraftUpdate, Never>?
    private let logger = Logger(subsystem: "com.songa.ShanghaiTemperature", category: "OpenSky")
    init(directory: URL? = nil, session: URLSession? = nil, refreshInterval: TimeInterval = 600) {
        legacyDirectory = FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("ShanghaiTemperature/Aircraft-v1")
        files = AircraftSharedFiles(directory: directory)
        self.refreshInterval = refreshInterval.isFinite ? max(600, refreshInterval) : 600
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 8
            config.timeoutIntervalForResource = 12
            config.waitsForConnectivity = false
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
    }

    func load(bounds: AircraftBounds) async -> AircraftUpdate {
        guard bounds.isValid else {
            return AircraftUpdate(record: nil, refreshAfter: Date().addingTimeInterval(60), remainingCredits: nil)
        }
        let result: AircraftUpdate
        if let inFlight {
            result = await inFlight.value
        } else {
            let task = Task { await self.fetch() }
            inFlight = task
            result = await task.value
            inFlight = nil
        }
        let now = Date()
        let scoped = result.record.flatMap { record in
            record.fetchedAt <= now ? record.scoped(to: bounds, at: now) : nil
        }
        return AircraftUpdate(record: scoped,
            refreshAfter: result.refreshAfter, remainingCredits: result.remainingCredits)
    }

    func requestStatus() -> AircraftRequestStatus? {
        guard let state = try? files.snapshot() else { return nil }
        return AircraftRequestStatus(interval: refreshInterval,
            nextRequest: max(state.nextAllowedAt, floor), updatedAt: Date(),
            migrationPending: !state.migratedRoles.isSuperset(of: ["app", "widget"]))
    }

    private func legacyDeadline() throws -> Date {
        let own = try AircraftSharedFiles.readIfPresent(Date.self,
            at: legacyDirectory.appendingPathComponent("next-request.json")) ?? .distantPast
        return max(own, try AircraftRequestStatus.legacyDeadline())
    }

    private func fetch() async -> AircraftUpdate {
        if record == nil,
           let saved = try? AircraftSharedFiles.readIfPresent(AircraftRecord.self,
               at: legacyDirectory.appendingPathComponent("positions.json")),
           saved.schema == 1, saved.bounds.isValid {
            record = saved
        }
        let pause = AircraftPauseSettings.current
        let claim: (AircraftSharedState, UUID?)
        do {
            claim = try files.claim(role: AircraftSharedFiles.role, legacyDeadline: legacyDeadline,
                interval: refreshInterval, floor: floor, paused: pause.paused)
        } catch {
            logger.error("Shared request state unavailable: \(String(describing: error), privacy: .public)")
            return AircraftUpdate(record: record, refreshAfter: Date().addingTimeInterval(60), remainingCredits: nil)
        }
        var state = claim.0
        if let id = claim.1, Date() < state.nextAllowedAt {
            do {
                var request = URLRequest(url: try AircraftDecoder.url(bounds: .acquisition))
                request.timeoutInterval = 8
                logger.notice("Request start id=\(id.uuidString, privacy: .public) pid=\(ProcessInfo.processInfo.processIdentifier)")
                let (data, response) = try await AircraftPauseSettings.data(for: request, session: session)
                let receivedAt = Date()
                guard let http = response as? HTTPURLResponse else { throw AircraftServiceError.invalidResponse }
                let credits = http.value(forHTTPHeaderField: "X-Rate-Limit-Remaining").flatMap(Int.init)
                var delay = refreshInterval
                if let value = http.value(forHTTPHeaderField: "Retry-After") {
                    if let seconds = Double(value), seconds.isFinite, seconds >= 0 {
                        delay = max(delay, seconds)
                    } else {
                        let formatter = DateFormatter()
                        formatter.locale = Locale(identifier: "en_US_POSIX")
                        formatter.timeZone = TimeZone(secondsFromGMT: 0)
                        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                        if let date = formatter.date(from: value) {
                            delay = max(delay, date.timeIntervalSince(receivedAt))
                        }
                    }
                }
                if let value = http.value(forHTTPHeaderField: "X-Rate-Limit-Retry-After-Seconds"),
                   let seconds = Double(value), seconds.isFinite, seconds >= 0 {
                    delay = max(delay, seconds)
                }
                floor = max(floor, receivedAt.addingTimeInterval(delay))
                state = try files.applyResponse(id: id, deadline: floor, credits: credits)
                logger.notice("Response id=\(id.uuidString, privacy: .public) status=\(http.statusCode) waitSeconds=\(delay)")
                guard http.statusCode == 200, data.count <= 5_000_000 else {
                    throw AircraftServiceError.invalidResponse
                }
                let current = AircraftPauseSettings.current
                if !current.paused, current.generation == pause.generation {
                    var saved = try AircraftDecoder.decode(data, bounds: .acquisition, now: receivedAt)
                    saved.batchID = id
                    state = try files.publish(saved, id: id)
                }
            } catch {
                logger.error("Request failed id=\(id.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
        }
        // Reload the published ID on every check, even if the other process won.
        if let latest = state.batches.last, latest.id != record?.batchID {
            if let saved = try? files.record(for: latest) { record = saved }
        }
        let retry = state.migratedRoles.isSuperset(of: ["app", "widget"])
            ? max(state.nextAllowedAt, floor)
            : max(Date().addingTimeInterval(60), state.nextAllowedAt)
        return AircraftUpdate(record: record, refreshAfter: retry, remainingCredits: state.remainingCredits)
    }
}

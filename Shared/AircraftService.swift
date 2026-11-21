import Foundation
import CoreFoundation

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
        return age >= 0 && age < 120
            && longitude.isFinite && latitude.isFinite
            && bounds.contains(longitude: longitude, latitude: latitude)
    }
}

struct AircraftRecord: Codable, Sendable {
    let schema: Int
    let bounds: AircraftBounds
    let fetchedAt: Date
    let states: [AircraftState]

    func visible(at now: Date) -> [AircraftState] {
        guard schema == 1, bounds.isValid, now >= fetchedAt else { return [] }
        return states.filter { $0.isVisible(at: now, bounds: bounds) }
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

actor AircraftStore {
    static let shared = AircraftStore()
    private let directory: URL
    private let session: URLSession
    private let refreshInterval: TimeInterval
    private var record: AircraftRecord?
    private var nextRequest: Date = .distantPast
    private var remainingCredits: Int?
    private var inFlight: Task<AircraftUpdate, Never>?
    private var inFlightBounds: AircraftBounds?

    init(directory: URL? = nil, session: URLSession? = nil, refreshInterval: TimeInterval = 300) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("ShanghaiTemperature/Aircraft-v1", isDirectory: true)
        self.refreshInterval = refreshInterval.isFinite ? max(60, refreshInterval) : 300
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

    private var file: URL { directory.appendingPathComponent("positions.json") }
    private var throttleFile: URL { directory.appendingPathComponent("next-request.json") }

    func load(bounds: AircraftBounds) async -> AircraftUpdate {
        if let task = inFlight {
            let requestedBounds = inFlightBounds
            let result = await task.value
            if requestedBounds == bounds {
                // Share failures and empty responses as well as successful ones.
                return result
            }
            // Another geographic request is still subject to the same throttle.
            return update(bounds: bounds, now: Date())
        }
        let task = Task { await self.fetch(bounds: bounds) }
        inFlightBounds = bounds
        inFlight = task
        let result = await task.value
        inFlight = nil
        inFlightBounds = nil
        return result
    }

    private func fetch(bounds: AircraftBounds) async -> AircraftUpdate {
        let now = Date()
        guard bounds.isValid else {
            return AircraftUpdate(record: nil, refreshAfter: now.addingTimeInterval(300), remainingCredits: nil)
        }
        if record == nil, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(AircraftRecord.self, from: data),
           saved.schema == 1, saved.bounds.isValid {
            record = saved
        }
        if let data = try? Data(contentsOf: throttleFile),
           let saved = try? JSONDecoder().decode(Date.self, from: data) {
            nextRequest = max(nextRequest, saved)
        }
        if nextRequest > now { return update(bounds: bounds, now: now) }
        nextRequest = now.addingTimeInterval(refreshInterval)
        persistThrottle()
        do {
            var request = URLRequest(url: try AircraftDecoder.url(bounds: bounds))
            request.timeoutInterval = 8
            let (data, response) = try await session.data(for: request)
            let receivedAt = Date()
            guard let http = response as? HTTPURLResponse else {
                throw AircraftServiceError.invalidResponse
            }
            remainingCredits = http.value(forHTTPHeaderField: "X-Rate-Limit-Remaining").flatMap(Int.init)
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
            if http.statusCode == 429 || remainingCredits == 0 { delay = max(delay, 3600) }
            if http.statusCode == 401 || http.statusCode == 403 { delay = max(delay, 3600) }
            nextRequest = receivedAt.addingTimeInterval(delay)
            persistThrottle()
            guard http.statusCode == 200, data.count <= 5_000_000 else {
                throw AircraftServiceError.invalidResponse
            }
            let saved = try AircraftDecoder.decode(data, bounds: bounds, now: receivedAt)
            record = saved
            try? JSONEncoder().encode(saved).write(to: file, options: .atomic)
        } catch {
            NSLog("Aircraft refresh failed: %@", String(describing: error))
        }
        return update(bounds: bounds, now: Date())
    }

    private func update(bounds: AircraftBounds, now: Date) -> AircraftUpdate {
        let visible = record.flatMap { saved -> AircraftRecord? in
            guard saved.bounds == bounds, saved.fetchedAt <= now else { return nil }
            return AircraftRecord(schema: 1, bounds: bounds, fetchedAt: saved.fetchedAt,
                states: saved.visible(at: now))
        }
        return AircraftUpdate(
            record: visible,
            refreshAfter: nextRequest,
            remainingCredits: remainingCredits)
    }

    private func persistThrottle() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(nextRequest).write(to: throttleFile, options: .atomic)
    }
}

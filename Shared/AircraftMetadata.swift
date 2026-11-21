import Foundation

struct AircraftMetadata: Sendable {
    let model: String?
    let airline: String?
    let flightNumber: String?

    var label: String? {
        let flight = [airline, flightNumber].compactMap { $0 }.joined(separator: " ")
        let parts = [flight.isEmpty ? nil : flight, model].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct AircraftMetadataValue: Codable, Sendable {
    let model: String?
    let airline: String?
    let flightNumber: String?
}

private struct AircraftMetadataCache: Codable {
    let schema: Int
    let key: String
    let fetchedAt: Date
    let expiresAt: Date
    let value: AircraftMetadataValue?
}

private struct AircraftMetadataFetch: Sendable {
    let value: AircraftMetadataValue?
    let retryAfter: Date?
    let succeeded: Bool
}

actor AircraftMetadataStore {
    static let shared = AircraftMetadataStore()

    private let directory: URL
    private let session: URLSession
    private var cache: [String: AircraftMetadataCache] = [:]
    private var inFlight: [String: Task<AircraftMetadataValue?, Never>] = [:]
    private var activeRequests = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var blockedUntil: Date = .distantPast

    init(directory: URL? = nil, session: URLSession? = nil) {
        self.directory = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("ShanghaiTemperature/AircraftMetadata-v1",
            isDirectory: true)
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 8
            config.timeoutIntervalForResource = 12
            config.waitsForConnectivity = false
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
    }

    func load(icao24: String, callsign: String?) async -> AircraftMetadata {
        let id = icao24.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let call = callsign?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        async let aircraft = lookup(kind: "aircraft", identifier: id)
        async let flight = lookup(kind: "callsign", identifier: call ?? "")
        let (aircraftValue, flightValue) = await (aircraft, flight)
        return AircraftMetadata(model: aircraftValue?.model,
            airline: flightValue?.airline, flightNumber: flightValue?.flightNumber)
    }

    func cachedModel(icao24: String) -> String? {
        let id = icao24.lowercased()
        guard id.range(of: "^[0-9a-f]{6}$", options: .regularExpression) != nil else {
            return nil
        }
        let now = Date()
        guard let saved = cached(key: "aircraft-" + id),
              saved.fetchedAt <= now, saved.expiresAt > now else {
            return nil
        }
        return saved.value?.model
    }

    func loadModel(icao24: String) async -> String? {
        await lookup(kind: "aircraft", identifier: icao24.lowercased())?.model
    }

    private func lookup(kind: String, identifier: String) async -> AircraftMetadataValue? {
        let pattern = kind == "aircraft" ? "^[0-9a-f]{6}$" : "^[A-Z0-9]{2,12}$"
        guard identifier.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }
        let key = kind + "-" + identifier
        let now = Date()
        if let saved = cached(key: key), saved.fetchedAt <= now, saved.expiresAt > now {
            return saved.value
        }
        if let task = inFlight[key] { return await task.value }
        let task = Task { await self.fetchAndCache(kind: kind, identifier: identifier, key: key) }
        inFlight[key] = task
        let value = await task.value
        inFlight[key] = nil
        return value
    }

    private func cached(key: String) -> AircraftMetadataCache? {
        if let saved = cache[key] { return saved }
        let file = directory.appendingPathComponent(key + ".json")
        guard let data = try? Data(contentsOf: file), data.count <= 100_000,
              let saved = try? JSONDecoder().decode(AircraftMetadataCache.self, from: data),
              saved.schema == 1, saved.key == key,
              saved.expiresAt > saved.fetchedAt else { return nil }
        cache[key] = saved
        return saved
    }

    private func acquireSlot() async {
        if activeRequests < 2 {
            activeRequests += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func releaseSlot() {
        if waiters.isEmpty {
            activeRequests -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    private func fetchAndCache(kind: String, identifier: String,
                               key: String) async -> AircraftMetadataValue? {
        await acquireSlot()
        defer { releaseSlot() }
        restoreThrottle()
        guard !Task.isCancelled, Date() >= blockedUntil else { return nil }
        let result = await request(kind: kind, identifier: identifier)
        if let retry = result.retryAfter {
            blockedUntil = max(blockedUntil, retry)
            persistThrottle()
        }
        let now = Date()
        let lifetime: TimeInterval
        if result.succeeded {
            lifetime = kind == "aircraft" ? 30 * 86400 : 30 * 60
        } else {
            lifetime = 15 * 60
        }
        let saved = AircraftMetadataCache(schema: 1, key: key, fetchedAt: now,
            expiresAt: now.addingTimeInterval(lifetime), value: result.value)
        cache[key] = saved
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(
                to: directory.appendingPathComponent(key + ".json"), options: .atomic)
        } catch {
            // Keep successful results and negative-cache entries in memory.
        }
        return result.value
    }

    private func restoreThrottle() {
        let file = directory.appendingPathComponent("throttle.json")
        if let data = try? Data(contentsOf: file),
           let date = try? JSONDecoder().decode(Date.self, from: data) {
            blockedUntil = max(blockedUntil, date)
        }
    }

    private func persistThrottle() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(blockedUntil).write(
            to: directory.appendingPathComponent("throttle.json"), options: .atomic)
    }

    private func request(kind: String, identifier: String) async -> AircraftMetadataFetch {
        let failure = AircraftMetadataFetch(value: nil, retryAfter: nil, succeeded: false)
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.adsbdb.com"
        components.path = "/v0/" + kind + "/" + identifier
        guard let url = components.url else { return failure }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return failure }
            if http.statusCode != 200 {
                let retry = Self.retryDate(http, now: Date())
                return AircraftMetadataFetch(value: nil, retryAfter: retry, succeeded: false)
            }
            guard data.count <= 1_000_000,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = root["response"] as? [String: Any] else { return failure }
            if kind == "aircraft" {
                guard let aircraft = response["aircraft"] as? [String: Any],
                      Self.text(aircraft["mode_s"])?.lowercased() == identifier else { return failure }
                let model = Self.text(aircraft["icao_type"]) ?? Self.text(aircraft["type"])
                guard model != nil else { return failure }
                return AircraftMetadataFetch(value: AircraftMetadataValue(
                    model: model, airline: nil, flightNumber: nil),
                    retryAfter: nil, succeeded: true)
            }
            guard let route = response["flightroute"] as? [String: Any],
                  Self.text(route["callsign"])?.uppercased() == identifier
                    || Self.text(route["callsign_icao"])?.uppercased() == identifier
                    || Self.text(route["callsign_iata"])?.uppercased() == identifier else { return failure }
            let airline = route["airline"] as? [String: Any]
            let names = ["CES": "东航", "CCA": "国航", "CSN": "南航",
                         "CHH": "海航", "CXA": "厦航", "CSZ": "深航",
                         "CDG": "山航", "CSC": "川航", "CQH": "春秋",
                         "DKH": "吉祥", "BAW": "英航"]
            let code = Self.text(airline?["icao"])?.uppercased()
            let name = code.flatMap { names[$0] } ?? Self.text(airline?["name"])
            let flight = Self.text(route["callsign_iata"])
            guard name != nil || flight != nil else { return failure }
            return AircraftMetadataFetch(value: AircraftMetadataValue(
                model: nil, airline: name, flightNumber: flight),
                retryAfter: nil, succeeded: true)
        } catch {
            return failure
        }
    }

    private static func text(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 120,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return value
    }

    private static func retryDate(_ response: HTTPURLResponse, now: Date) -> Date? {
        var delay: TimeInterval = response.statusCode == 429 ? 900 : 0
        if response.statusCode == 401 || response.statusCode == 403 { delay = 3600 }
        if let raw = response.value(forHTTPHeaderField: "Retry-After") {
            if let seconds = Double(raw), seconds.isFinite, seconds >= 0 {
                delay = max(delay, seconds)
            } else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                if let date = formatter.date(from: raw) {
                    delay = max(delay, date.timeIntervalSince(now))
                }
            }
        }
        return delay > 0 ? now.addingTimeInterval(delay) : nil
    }
}

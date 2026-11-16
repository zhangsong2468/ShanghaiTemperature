import Foundation

enum ForecastSource: String, Codable, Sendable {
    case regular, extended
    var count: Int { self == .regular ? 15 : 30 }
    static func source(for period: ForecastPeriod) -> ForecastSource {
        period == .month ? .extended : .regular
    }

    var url: URL {
        var url = URLComponents()
        url.scheme = "https"
        url.host = self == .regular ? "api.open-meteo.com" : "seasonal-api.open-meteo.com"
        url.path = self == .regular ? "/v1/forecast" : "/v1/seasonal"
        url.queryItems = [
            URLQueryItem(name: "latitude", value: "31.2304"),
            URLQueryItem(name: "longitude", value: "121.4737"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "temperature_unit", value: "celsius"),
            URLQueryItem(name: "timezone", value: "Asia/Shanghai"),
            URLQueryItem(name: "forecast_days", value: String(count))
        ]
        if self == .extended { url.queryItems?.append(URLQueryItem(name: "models", value: "ecmwf_ec46")) }
        return url.url!
    }
}

enum WeatherError: Error {
    case httpStatus(Int), invalidResponse, invalidUnits, invalidDates, invalidTemperature, incompleteEnsemble
}

struct ForecastRecord: Codable, Sendable {
    let version: Int
    let source: ForecastSource
    let fetchedAt: Date
    let days: [TemperatureDay]

    static let refreshInterval: TimeInterval = 3 * 60 * 60
    static let maximumCacheAge: TimeInterval = 48 * 60 * 60

    func isFresh(at now: Date) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        return age >= 0 && age < Self.refreshInterval
            && ShanghaiTime.calendar.isDate(fetchedAt, inSameDayAs: now)
    }

    func snapshot(for period: ForecastPeriod, at now: Date, justFetched: Bool = false) -> WeatherSnapshot {
        let age = now.timeIntervalSince(fetchedAt)
        let today = ShanghaiTime.calendar.startOfDay(for: now)
        guard age >= 0, age <= Self.maximumCacheAge,
              let first = days.firstIndex(where: { $0.date == today }) else {
            return WeatherSnapshot(period: period, days: [], status: .unavailable, fetchedAt: fetchedAt)
        }
        let selected = days.dropFirst(first).prefix(period.rawValue).enumerated().map { index, day in
            TemperatureDay(index: index, date: day.date, maximum: day.maximum, minimum: day.minimum)
        }
        let status: WeatherStatus = !isFresh(at: now) || selected.count < period.rawValue
            ? .stale : justFetched ? .fresh : .cached
        return WeatherSnapshot(period: period, days: selected, status: status, fetchedAt: fetchedAt)
    }
}

enum ForecastDecoder {
    private struct Response: Decodable {
        let timezone: String
        let daily_units: [String: String]
        let daily: Daily
    }

    private struct Daily: Decodable {
        let dates: [String]
        let series: [String: [Double?]]
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            dates = try container.decode([String].self, forKey: Key("time"))
            var parsed: [String: [Double?]] = [:]
            for key in container.allKeys where key.stringValue.hasPrefix("temperature_2m_") {
                parsed[key.stringValue] = try container.decode([Double?].self, forKey: key)
            }
            series = parsed
        }
    }

    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { return nil }
    }

    static func decode(_ data: Data, source: ForecastSource, fetchedAt: Date) throws -> ForecastRecord {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.timezone == "Asia/Shanghai" else { throw WeatherError.invalidDates }
        let count = source.count
        guard response.daily.dates.count == count else { throw WeatherError.invalidDates }
        let today = ShanghaiTime.calendar.startOfDay(for: fetchedAt)
        let dates = try response.daily.dates.enumerated().map { index, text -> Date in
            guard let date = ShanghaiTime.parseDay(text),
                  date == ShanghaiTime.calendar.date(byAdding: .day, value: index, to: today) else {
                throw WeatherError.invalidDates
            }
            return date
        }
        // EC46 returns the control member plus member01...member50.
        // Average daily highs separately from daily lows; never average hourly
        // temperatures first (that would suppress the daily temperature range).
        let suffixes = source == .extended ? [""] + (1...50).map { String(format: "_member%02d", $0) } : [""]
        var highs = Array(repeating: 0.0, count: count)
        var lows = Array(repeating: 0.0, count: count)
        for suffix in suffixes {
            let highKey = "temperature_2m_max" + suffix
            let lowKey = "temperature_2m_min" + suffix
            guard response.daily_units[highKey] == "°C", response.daily_units[lowKey] == "°C" else {
                throw WeatherError.invalidUnits
            }
            guard let high = response.daily.series[highKey], let low = response.daily.series[lowKey],
                  high.count == count, low.count == count else {
                throw WeatherError.incompleteEnsemble
            }
            for index in 0..<count {
                guard let h = high[index], let l = low[index], h.isFinite, l.isFinite,
                      (-90...65).contains(h), (-90...65).contains(l), h >= l else {
                    throw WeatherError.invalidTemperature
                }
                highs[index] += h / Double(suffixes.count)
                lows[index] += l / Double(suffixes.count)
            }
        }
        let days = (0..<count).map {
            TemperatureDay(index: $0, date: dates[$0], maximum: highs[$0], minimum: lows[$0])
        }
        return ForecastRecord(version: 1, source: source, fetchedAt: fetchedAt, days: days)
    }

    static func validateCached(_ record: ForecastRecord, source: ForecastSource) -> Bool {
        guard record.version == 1, record.source == source, record.days.count == source.count else { return false }
        let firstDate = ShanghaiTime.calendar.startOfDay(for: record.fetchedAt)
        return record.days.enumerated().allSatisfy { index, day in
            day.index == index && day.date == ShanghaiTime.calendar.date(byAdding: .day, value: index, to: firstDate)
                && day.maximum.isFinite && day.minimum.isFinite
                && (-90...65).contains(day.maximum) && (-90...65).contains(day.minimum)
                && day.maximum >= day.minimum
        }
    }
}

actor WeatherStore {
    static let shared = WeatherStore()
    private let directory: URL
    private let session: URLSession
    private var records: [ForecastSource: ForecastRecord] = [:]
    private var inFlight: [ForecastSource: Task<ForecastRecord, Error>] = [:]
    private var retryAfter: [ForecastSource: Date] = [:]

    init(directory: URL? = nil, session: URLSession? = nil) {
        // App and extension each use their own sandbox. All three widgets live
        // in one extension and share its cache; no App Group entitlement needed.
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShanghaiTemperature/Weather-v1", isDirectory: true)
        if let session { self.session = session } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 18
            configuration.waitsForConnectivity = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    private func cacheURL(_ source: ForecastSource) -> URL {
        directory.appendingPathComponent(source.rawValue + ".json")
    }

    private func read(_ source: ForecastSource) -> ForecastRecord? {
        if let record = records[source] { return record }
        guard let data = try? Data(contentsOf: cacheURL(source)),
              let record = try? JSONDecoder().decode(ForecastRecord.self, from: data),
              ForecastDecoder.validateCached(record, source: source) else { return nil }
        records[source] = record
        return record
    }

    private func persist(_ record: ForecastRecord) {
        // A read-only/full disk must not turn a successful network load into failure.
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(record).write(to: cacheURL(record.source), options: .atomic)
        } catch { /* Keep the validated record in memory. */ }
    }

    func load(_ period: ForecastPeriod, now: Date = Date()) async -> WeatherSnapshot {
        let source = ForecastSource.source(for: period)
        let cached = read(source)
        if let cached, cached.isFresh(at: now) { return cached.snapshot(for: period, at: now) }
        if let retry = retryAfter[source], retry > now {
            return cached?.snapshot(for: period, at: now)
                ?? WeatherSnapshot(period: period, days: [], status: .unavailable, fetchedAt: nil)
        }
        // Actor reentrancy means 7-day and 15-day requests may overlap. Reuse
        // the same Task so they issue one HTTP request, including after failure.
        let task: Task<ForecastRecord, Error>
        if let pending = inFlight[source] { task = pending } else {
            let session = self.session
            task = Task {
                var request = URLRequest(url: source.url)
                request.timeoutInterval = 12
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw WeatherError.invalidResponse }
                guard (200..<300).contains(http.statusCode) else { throw WeatherError.httpStatus(http.statusCode) }
                guard data.count <= 2_000_000 else { throw WeatherError.invalidResponse }
                return try ForecastDecoder.decode(data, source: source, fetchedAt: Date())
            }
            inFlight[source] = task
        }
        do {
            let record = try await task.value
            inFlight[source] = nil
            retryAfter[source] = nil
            records[source] = record
            persist(record)
            return record.snapshot(for: period, at: max(Date(), record.fetchedAt), justFetched: true)
        } catch {
            inFlight[source] = nil
            retryAfter[source] = Date().addingTimeInterval(30 * 60)
            return cached?.snapshot(for: period, at: Date())
                ?? WeatherSnapshot(period: period, days: [], status: .unavailable, fetchedAt: nil)
        }
    }

    static func nextRefresh(for snapshot: WeatherSnapshot, after now: Date) -> Date {
        let due: Date
        if snapshot.status == .stale || snapshot.status == .unavailable {
            due = now.addingTimeInterval(30 * 60)
        } else {
            due = (snapshot.fetchedAt ?? now).addingTimeInterval(ForecastRecord.refreshInterval)
        }
        return max(now.addingTimeInterval(60), min(due, ShanghaiTime.nextMidnight(after: now)))
    }
}

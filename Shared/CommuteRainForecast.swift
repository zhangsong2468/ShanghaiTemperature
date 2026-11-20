import Foundation

enum CommuteRainCondition: Equatable, Sendable {
    case unknown
    case dry
    case rain(String)
}

enum CommuteRainIntensity: Int, Codable, Sendable {
    case none, light, moderate, heavy

    // Application hourly-amount bands, not official 24-hour rainfall categories.
    init(millimetres: Double) {
        self = millimetres <= 0 ? .none : millimetres < 2.5 ? .light : millimetres < 8 ? .moderate : .heavy
    }

    var label: String {
        switch self {
        case .none: return ""
        case .light: return "小雨"
        case .moderate: return "中雨"
        case .heavy: return "大雨"
        }
    }
}

struct CommuteRainHour: Codable, Sendable {
    let date: Date
    let rain: Double?
    let showers: Double?
    let snowfall: Double?
    let weatherCode: Int?
}

struct CommuteRainRecord: Codable, Sendable {
    let schema: Int
    let source: String
    let fetchedAt: Date
    let hours: [CommuteRainHour]

    static let source = "open-meteo-shanghai-hourly-v1"
    static let maximumAge: TimeInterval = 3 * 3600
    static let retryInterval: TimeInterval = 15 * 60

    func isUsable(at now: Date) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        return age >= 0 && age < Self.maximumAge && CommuteRainDecoder.validate(self)
    }

    func hasCompleteCoverage(at now: Date) -> Bool {
        guard isUsable(at: now) else { return false }
        let tomorrow = ShanghaiTime.nextMidnight(after: now)
        return [8, 9, 10, 19, 20, 21].allSatisfy { hour in
            let date = tomorrow.addingTimeInterval(Double(hour) * 3600)
            guard let sample = hours.first(where: { $0.date == date }),
                  sample.weatherCode != nil else { return false }
            if hour == 8 || hour == 19 { return true }
            return sample.rain != nil && sample.showers != nil && sample.snowfall != nil
        }
    }

    func message(at now: Date) -> String? {
        if case .rain(let text) = condition(at: now) {
            return text
        }
        return nil
    }

    func condition(at now: Date) -> CommuteRainCondition {
        guard hasCompleteCoverage(at: now) else { return .unknown }
        let tomorrow = ShanghaiTime.nextMidnight(after: now)
        let byDate = Dictionary(hours.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        func intensity(endingAt hour: Int) -> CommuteRainIntensity? {
            let end = tomorrow.addingTimeInterval(Double(hour) * 3600)
            guard let sample = byDate[end], let previous = byDate[end.addingTimeInterval(-3600)],
                  let rain = sample.rain, let showers = sample.showers,
                  let snow = sample.snowfall, let code = sample.weatherCode,
                  let previousCode = previous.weatherCode else { return nil }
            let amount = rain + showers
            // Weather codes describe an instant, not the preceding hour's rain
            // strength. Use both endpoints only to avoid ambiguous frozen/hail rain.
            let frozenOrHail: Set<Int> = [56, 57, 66, 67, 71, 73, 75, 77, 85, 86, 96, 99]
            if snow > 0 || frozenOrHail.contains(code) || frozenOrHail.contains(previousCode) {
                return nil
            }
            return CommuteRainIntensity(millimetres: amount)
        }
        // API timestamps label the preceding hour: 09:00 + 10:00 cover 08–10.
        guard let morningFirst = intensity(endingAt: 9), let morningLast = intensity(endingAt: 10),
              let eveningFirst = intensity(endingAt: 20), let eveningLast = intensity(endingAt: 21) else { return .unknown }
        let morning = morningFirst.rawValue > morningLast.rawValue ? morningFirst : morningLast
        let evening = eveningFirst.rawValue > eveningLast.rawValue ? eveningFirst : eveningLast
        if let text = Self.message(morning: morning, evening: evening) {
            return .rain(text)
        }
        return .dry
    }

    static func message(morning: CommuteRainIntensity, evening: CommuteRainIntensity) -> String? {
        if morning == .none && evening == .none { return nil }
        if evening == .none { return "明天上班有" + morning.label }
        if morning == .none { return "明天下班有" + evening.label }
        if morning == evening { return "明天上下班有" + morning.label }
        return "明天上班" + morning.label + "，下班" + evening.label
    }
}

enum CommuteRainDecoder {
    private struct Response: Decodable {
        let latitude: Double
        let longitude: Double
        let timezone: String
        let hourly_units: [String: String]
        let hourly: Hourly
    }

    private struct Hourly: Decodable {
        let time: [String]
        let rain: [Double?]
        let showers: [Double?]
        let snowfall: [Double?]
        let weather_code: [Int?]
    }

    static var url: URL {
        var url = URLComponents()
        url.scheme = "https"; url.host = "api.open-meteo.com"; url.path = "/v1/forecast"
        url.queryItems = [URLQueryItem(name: "latitude", value: "31.2304"),
            URLQueryItem(name: "longitude", value: "121.4737"),
            URLQueryItem(name: "hourly", value: "rain,showers,snowfall,weather_code"),
            URLQueryItem(name: "timezone", value: "Asia/Shanghai"),
            URLQueryItem(name: "precipitation_unit", value: "mm"),
            URLQueryItem(name: "forecast_days", value: "3")]
        return url.url!
    }

    static func decode(_ data: Data, fetchedAt: Date) throws -> CommuteRainRecord {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.timezone == "Asia/Shanghai",
              abs(response.latitude - 31.2304) < 0.5, abs(response.longitude - 121.4737) < 0.5 else {
            throw WeatherError.invalidResponse
        }
        let units = response.hourly_units
        guard units["time"] == "iso8601", units["rain"] == "mm", units["showers"] == "mm",
              units["snowfall"] == "cm", units["weather_code"] == "wmo code" else { throw WeatherError.invalidUnits }
        let hourly = response.hourly
        guard hourly.time.count == 72, hourly.rain.count == 72, hourly.showers.count == 72,
              hourly.snowfall.count == 72, hourly.weather_code.count == 72 else { throw WeatherError.invalidResponse }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = ShanghaiTime.calendar; formatter.timeZone = ShanghaiTime.zone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"; formatter.isLenient = false
        let hours = try hourly.time.enumerated().map { index, text -> CommuteRainHour in
            guard let date = formatter.date(from: text), formatter.string(from: date) == text else {
                throw WeatherError.invalidDates
            }
            return CommuteRainHour(date: date, rain: hourly.rain[index], showers: hourly.showers[index],
                snowfall: hourly.snowfall[index], weatherCode: hourly.weather_code[index])
        }
        let record = CommuteRainRecord(schema: 1, source: CommuteRainRecord.source, fetchedAt: fetchedAt, hours: hours)
        guard validate(record) else { throw WeatherError.invalidResponse }
        return record
    }

    static func validate(_ record: CommuteRainRecord) -> Bool {
        guard record.schema == 1, record.source == CommuteRainRecord.source, record.hours.count == 72 else { return false }
        let start = ShanghaiTime.calendar.startOfDay(for: record.fetchedAt)
        let codes: Set<Int> = [0, 1, 2, 3, 45, 48, 51, 53, 55, 56, 57, 61, 63, 65, 66, 67,
                               71, 73, 75, 77, 80, 81, 82, 85, 86, 95, 96, 99]
        return record.hours.enumerated().allSatisfy { index, sample in
            sample.date == start.addingTimeInterval(Double(index) * 3600)
                && [sample.rain, sample.showers, sample.snowfall].allSatisfy { value in
                    value == nil || (value!.isFinite && value! >= 0)
                } && (sample.weatherCode == nil || codes.contains(sample.weatherCode!))
        }
    }
}

struct CommuteRainUpdate: Sendable {
    let record: CommuteRainRecord?
    let refreshAfter: Date
}

actor CommuteRainStore {
    static let shared = CommuteRainStore()
    private let directory: URL
    private let session: URLSession
    private var record: CommuteRainRecord?
    private var inFlight: Task<CommuteRainRecord, Error>?
    private var retryAfter: Date?

    init(directory: URL? = nil, session: URLSession? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShanghaiTemperature/CommuteRain-v1", isDirectory: true)
        if let session { self.session = session } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 18
            config.waitsForConnectivity = false; config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
    }

    private var file: URL { directory.appendingPathComponent("shanghai.json") }

    private func cached() -> CommuteRainRecord? {
        if let record { return record }
        guard let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode(CommuteRainRecord.self, from: data),
              CommuteRainDecoder.validate(saved) else { return nil }
        record = saved
        return saved
    }

    private func update(_ saved: CommuteRainRecord?, now: Date, retry: Date? = nil) -> CommuteRainUpdate {
        let usable = saved.flatMap { $0.isUsable(at: now) ? $0 : nil }
        let due: Date
        if let retry {
            due = retry
        } else if let usable, usable.hasCompleteCoverage(at: now) {
            due = usable.fetchedAt.addingTimeInterval(CommuteRainRecord.maximumAge)
        } else {
            due = now.addingTimeInterval(CommuteRainRecord.retryInterval)
        }
        return CommuteRainUpdate(record: usable,
            refreshAfter: max(now.addingTimeInterval(60), min(due, ShanghaiTime.nextMidnight(after: now))))
    }

    func load(now: Date = Date()) async -> CommuteRainUpdate {
        let saved = cached()
        if let saved, saved.hasCompleteCoverage(at: now),
           ShanghaiTime.calendar.isDate(saved.fetchedAt, inSameDayAs: now) {
            return update(saved, now: now)
        }
        if let retryAfter, retryAfter > now { return update(saved, now: now, retry: retryAfter) }
        let task: Task<CommuteRainRecord, Error>
        if let inFlight { task = inFlight } else {
            let session = self.session
            task = Task {
                var request = URLRequest(url: CommuteRainDecoder.url)
                request.timeoutInterval = 12
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw WeatherError.invalidResponse }
                guard (200..<300).contains(http.statusCode) else { throw WeatherError.httpStatus(http.statusCode) }
                guard data.count <= 2_000_000 else { throw WeatherError.invalidResponse }
                return try CommuteRainDecoder.decode(data, fetchedAt: now)
            }
            inFlight = task
        }
        do {
            let fetched = try await task.value
            inFlight = nil
            retryAfter = fetched.hasCompleteCoverage(at: now)
                ? nil : now.addingTimeInterval(CommuteRainRecord.retryInterval)
            record = fetched
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try JSONEncoder().encode(fetched).write(to: file, options: .atomic)
            } catch { /* A successful forecast remains usable in memory. */ }
            return update(fetched, now: now, retry: retryAfter)
        } catch {
            inFlight = nil; retryAfter = now.addingTimeInterval(CommuteRainRecord.retryInterval)
            NSLog("Shanghai commute rain refresh failed: %@", String(describing: error))
            return update(saved, now: now, retry: retryAfter)
        }
    }
}

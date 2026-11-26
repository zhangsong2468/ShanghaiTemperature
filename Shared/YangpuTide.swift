import Foundation

struct TideReading: Codable, Sendable {
    let date: Date
    let level: Double
}

struct YangpuTideSnapshot: Codable, Sendable {
    static let maximumObservationAge: TimeInterval = 30 * 60
    static let maximumForecastGap: TimeInterval = 12 * 3600

    var observations: [TideReading] = []
    var forecasts: [TideReading] = []

    mutating func updateObservations(_ readings: [TideReading], now: Date) {
        var byDate = Dictionary(observations.map { ($0.date, $0) }, uniquingKeysWith: { _, newer in newer })
        for reading in readings { byDate[reading.date] = reading }
        observations = byDate.values
            .filter { (0...Self.maximumObservationAge).contains(now.timeIntervalSince($0.date)) }
            .sorted { $0.date < $1.date }
    }

    mutating func updateForecasts(_ readings: [TideReading], now: Date) {
        guard let first = readings.first else { return }
        // A later forecast may shift an extremum's time. Replace the
        // overlapping segment, retaining past forecasts for today's maximum.
        let overlap = first.date.addingTimeInterval(-2 * 3600)
        let retention = now.addingTimeInterval(-48 * 3600)
        forecasts = forecasts.filter { $0.date >= retention && $0.date < overlap } + readings
    }

    private enum Direction: String {
        case rising = "涨潮"
        case falling = "退潮"
    }

    private func extremum(at index: Int) -> Direction? {
        guard index > 0, index + 1 < forecasts.count else { return nil }
        let before = forecasts[index - 1]
        let point = forecasts[index]
        let after = forecasts[index + 1]
        guard point.date.timeIntervalSince(before.date) <= Self.maximumForecastGap,
              after.date.timeIntervalSince(point.date) <= Self.maximumForecastGap else { return nil }
        if point.level > before.level && point.level > after.level { return .rising }
        if point.level < before.level && point.level < after.level { return .falling }
        return nil
    }

    func line(at now: Date) -> String? {
        guard let latest = observations.last,
              (0...Self.maximumObservationAge).contains(now.timeIntervalSince(latest.date)),
              let previous = observations.first(where: {
                  let interval = latest.date.timeIntervalSince($0.date)
                  return interval > 0 && interval <= 15 * 60
              }) else { return nil }

        let change = latest.level - previous.level
        guard abs(change) >= 0.02 else { return nil }
        let direction: Direction = change > 0 ? .rising : .falling

        let today = ShanghaiTime.calendar.startOfDay(for: now)
        let tomorrow = ShanghaiTime.nextMidnight(after: now)
        // Require a continuous forecast sequence spanning the entire day.
        // A rolling response containing only the remaining low tide is insufficient.
        guard let beforeToday = forecasts.lastIndex(where: { $0.date < today }),
              let afterToday = forecasts.firstIndex(where: { $0.date >= tomorrow }),
              beforeToday + 1 < afterToday else { return nil }

        let todayIndices = (beforeToday + 1)..<afterToday
        guard todayIndices.allSatisfy({ extremum(at: $0) != nil }),
              let peak = todayIndices.filter({ extremum(at: $0) == .rising })
                  .map({ forecasts[$0].level }).max(),
              let next = forecasts.indices.first(where: {
                  forecasts[$0].date > now && extremum(at: $0) == direction
              }) else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = ShanghaiTime.zone
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: forecasts[next].date)
        return String(format: "杨浦滨江 · %@ · %.1f / %.1f m %@",
                      locale: Locale(identifier: "en_US_POSIX"),
                      direction.rawValue, latest.level, peak, time)
    }
}

struct YangpuTideUpdate: Sendable {
    let snapshot: YangpuTideSnapshot?
    let refreshAfter: Date
}

actor YangpuTideStore {
    static let shared = YangpuTideStore()

    private enum Feed: String, Sendable {
        case observed = "SSSW"
        case predicted = "YJSW"

        var levelField: String { self == .observed ? "OUTWATER" : "YBCW" }

        var url: URL {
            URL(string: "https://swgxh.swj.sh.gov.cn/swj/swj/businessConvenientService/getList?type=" + rawValue)!
        }
    }

    private let session: URLSession
    private let cacheURL: URL?
    private var snapshot: YangpuTideSnapshot
    private var nextObservation = Date.distantPast
    private var nextForecast = Date.distantPast
    private var observationsAvailable = false
    private var forecastsAvailable = false
    private var inFlight: Task<YangpuTideUpdate, Never>?

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("ShanghaiTemperature/yangpu-tide-v1.json")
        cacheURL = file
        if let file, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(YangpuTideSnapshot.self, from: data) {
            snapshot = saved
        } else {
            snapshot = YangpuTideSnapshot()
        }
    }

    func refresh() async -> YangpuTideUpdate {
        if let inFlight { return await inFlight.value }
        let task = Task { await self.fetchDueData() }
        inFlight = task
        let update = await task.value
        inFlight = nil
        return update
    }

    private func fetchDueData() async -> YangpuTideUpdate {
        let now = Date()
        let observationDue = now >= nextObservation
        let forecastDue = now >= nextForecast
        if observationDue { nextObservation = now.addingTimeInterval(5 * 60) }
        if forecastDue { nextForecast = now.addingTimeInterval(30 * 60) }

        let session = self.session
        async let observation = Self.fetch(.observed, due: observationDue, session: session)
        async let forecast = Self.fetch(.predicted, due: forecastDue, session: session)
        let (observed, predicted) = await (observation, forecast)
        let receivedAt = Date()
        if observationDue {
            let usable = observed?.filter {
                (0...YangpuTideSnapshot.maximumObservationAge).contains(receivedAt.timeIntervalSince($0.date))
            } ?? []
            observationsAvailable = !usable.isEmpty
            snapshot.updateObservations(usable, now: receivedAt)
        }
        if forecastDue {
            forecastsAvailable = predicted?.contains(where: { $0.date > receivedAt }) ?? false
            if let predicted, forecastsAvailable {
                snapshot.updateForecasts(predicted, now: receivedAt)
            }
        }
        if (observationDue && observationsAvailable) || (forecastDue && forecastsAvailable),
           let cacheURL {
            try? FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(snapshot).write(to: cacheURL, options: .atomic)
        }
        return YangpuTideUpdate(
            snapshot: observationsAvailable && forecastsAvailable ? snapshot : nil,
            refreshAfter: min(nextObservation, nextForecast))
    }

    private static func fetch(_ feed: Feed, due: Bool, session: URLSession) async -> [TideReading]? {
        guard due else { return nil }
        do {
            let (data, response) = try await session.data(from: feed.url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return parse(data, levelField: feed.levelField)
        } catch {
            return nil
        }
    }

    static func parse(_ data: Data, levelField: String) -> [TideReading]? {
        guard let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              payload["code"] as? Int == 200,
              let rows = payload["data"] as? [[String: Any]] else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = ShanghaiTime.calendar
        formatter.timeZone = ShanghaiTime.zone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.isLenient = false

        var readings: [Date: TideReading] = [:]
        for row in rows where row["STATIONID"] as? String == "SW63401500" {
            guard let text = row["DATETIME"] as? String,
                  let date = formatter.date(from: text),
                  let value = row[levelField] as? String,
                  let level = Double(value), level.isFinite else { continue }
            readings[date] = TideReading(date: date, level: level)
        }
        return readings.values.sorted { $0.date < $1.date }
    }
}

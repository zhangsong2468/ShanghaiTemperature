import Foundation
import OSLog

struct TideReading: Codable, Sendable {
    let date: Date
    let level: Double
}

struct YangpuTideSnapshot: Codable, Sendable {
    static let maximumObservationAge: TimeInterval = 30 * 60
    private static let maximumForecastGap: TimeInterval = 12 * 3600

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
        // overlapping segment and retain earlier extrema as context.
        let overlap = first.date.addingTimeInterval(-2 * 3600)
        let retention = now.addingTimeInterval(-48 * 3600)
        forecasts = forecasts.filter { $0.date >= retention && $0.date < overlap } + readings
    }

    private enum Direction: String {
        case rising = "涨潮"
        case falling = "退潮"
    }

    enum DisplayFailure: String, Error {
        case observationMissingOrExpired = "observation_missing_or_expired"
        case needSecondObservation = "need_second_observation"
        case trendTooSmall = "trend_too_small"
        case noMatchingFutureTide = "no_matching_future_tide"
    }

    private func extremum(at index: Int) -> Direction? {
        let point = forecasts[index]
        // The feed lists successive highs and lows. At either edge of the
        // response we can classify a point using its one available neighbour.
        let neighbours = [index - 1, index + 1]
            .filter { forecasts.indices.contains($0) }
            .map { forecasts[$0] }
        guard !neighbours.isEmpty, neighbours.allSatisfy({
            let gap = abs($0.date.timeIntervalSince(point.date))
            return gap > 0 && gap <= Self.maximumForecastGap
        }) else { return nil }
        if neighbours.allSatisfy({ point.level > $0.level }) { return .rising }
        if neighbours.allSatisfy({ point.level < $0.level }) { return .falling }
        return nil
    }

    func line(at now: Date) -> String? {
        try? display(at: now).get()
    }

    func display(at now: Date) -> Result<String, DisplayFailure> {
        guard let latest = observations.last,
              (0...Self.maximumObservationAge).contains(now.timeIntervalSince(latest.date))
        else { return .failure(.observationMissingOrExpired) }
        guard let previous = observations.first(where: {
            let interval = latest.date.timeIntervalSince($0.date)
            return interval > 0 && interval <= 15 * 60
        }) else { return .failure(.needSecondObservation) }

        let change = latest.level - previous.level
        guard abs(change) >= 0.02 else { return .failure(.trendTooSmall) }
        let direction: Direction = change > 0 ? .rising : .falling

        guard let nextIndex = forecasts.indices.first(where: {
            forecasts[$0].date > now && extremum(at: $0) == direction
        }) else { return .failure(.noMatchingFutureTide) }
        let next = forecasts[nextIndex]

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = ShanghaiTime.zone
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: next.date)
        return .success(String(format: "杨浦滨江 · %@ · %.2f / %.2f m %@",
                               locale: Locale(identifier: "en_US_POSIX"),
                               direction.rawValue, latest.level, next.level, time))
    }
}

struct YangpuTideUpdate: Sendable {
    let snapshot: YangpuTideSnapshot?
    let refreshAfter: Date
}

actor YangpuTideStore {
    static let shared = YangpuTideStore()
    private static let logger = Logger(subsystem: "com.songa.ShanghaiTemperature", category: "YangpuTide")
    private static let stationID = "SW63401500"

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
        if let file, FileManager.default.fileExists(atPath: file.path) {
            do {
                let saved = try JSONDecoder().decode(YangpuTideSnapshot.self, from: Data(contentsOf: file))
                snapshot = saved
                Self.logger.notice("Cache loaded observations=\(saved.observations.count) forecasts=\(saved.forecasts.count)")
            } catch {
                snapshot = YangpuTideSnapshot()
                Self.logger.error("Cache read failed: \(String(describing: error), privacy: .public)")
            }
        } else {
            snapshot = YangpuTideSnapshot()
            Self.logger.notice("No tide cache at startup")
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
            if let observed, !observed.isEmpty, usable.isEmpty {
                Self.logger.warning("SSSW has no observation within the last 30 minutes")
            }
        }
        if forecastDue {
            forecastsAvailable = predicted?.contains(where: { $0.date > receivedAt }) ?? false
            if let predicted, forecastsAvailable {
                snapshot.updateForecasts(predicted, now: receivedAt)
            } else if let predicted, !predicted.isEmpty {
                Self.logger.warning("YJSW has no future tide readings")
            }
        }
        if (observationDue && observationsAvailable) || (forecastDue && forecastsAvailable),
           let cacheURL {
            do {
                try FileManager.default.createDirectory(
                    at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(snapshot).write(to: cacheURL, options: .atomic)
            } catch {
                Self.logger.error("Cache write failed: \(String(describing: error), privacy: .public)")
            }
        }

        let available = observationsAvailable && forecastsAvailable
        if available {
            switch snapshot.display(at: receivedAt) {
            case .success(let line):
                Self.logger.notice("Tide line ready: \(line, privacy: .public)")
            case .failure(let reason):
                Self.logger.notice("Tide line hidden reason=\(reason.rawValue, privacy: .public) observations=\(self.snapshot.observations.count) forecasts=\(self.snapshot.forecasts.count)")
            }
        } else {
            Self.logger.notice("Tide line hidden reason=feed_unavailable observed=\(self.observationsAvailable) forecast=\(self.forecastsAvailable)")
        }
        return YangpuTideUpdate(
            snapshot: available ? snapshot : nil,
            refreshAfter: min(nextObservation, nextForecast))
    }

    private static func fetch(_ feed: Feed, due: Bool, session: URLSession) async -> [TideReading]? {
        guard due else { return nil }
        let name = feed.rawValue
        logger.notice("Tide request start feed=\(name, privacy: .public) station=\(stationID, privacy: .public)")
        do {
            let (data, response) = try await session.data(from: feed.url)
            guard let http = response as? HTTPURLResponse else {
                logger.error("Tide request returned no HTTP status feed=\(name, privacy: .public)")
                return nil
            }
            guard http.statusCode == 200 else {
                logger.error("Tide HTTP error feed=\(name, privacy: .public) status=\(http.statusCode)")
                return nil
            }
            guard let readings = parse(data, levelField: feed.levelField) else {
                logger.error("Tide response invalid JSON or API status feed=\(name, privacy: .public) bytes=\(data.count)")
                return nil
            }
            guard let first = readings.first, let last = readings.last else {
                logger.warning("Tide response has no valid station rows feed=\(name, privacy: .public) station=\(stationID, privacy: .public)")
                return nil
            }
            let firstTime = ShanghaiTime.timestamp(first.date)
            let lastTime = ShanghaiTime.timestamp(last.date)
            logger.notice("Tide request success feed=\(name, privacy: .public) rows=\(readings.count) first=\(firstTime, privacy: .public) last=\(lastTime, privacy: .public) lastLevel=\(last.level) m")
            return readings
        } catch {
            let error = error as NSError
            logger.error("Tide network error feed=\(name, privacy: .public) domain=\(error.domain, privacy: .public) code=\(error.code) detail=\(error.localizedDescription, privacy: .public)")
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
        for row in rows where row["STATIONID"] as? String == stationID {
            guard let text = row["DATETIME"] as? String,
                  let date = formatter.date(from: text),
                  let value = row[levelField] as? String,
                  let level = Double(value), level.isFinite else { continue }
            readings[date] = TideReading(date: date, level: level)
        }
        return readings.values.sorted { $0.date < $1.date }
    }
}

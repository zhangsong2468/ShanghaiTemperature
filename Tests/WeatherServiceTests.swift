import XCTest
import Foundation
@testable import WeatherCore

final class StubWeatherProtocol: URLProtocol {
    static let lock = NSLock()
    static var responder: ((URLRequest) throws -> (Int, Data))?
    static var count = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        let handler = Self.responder
        Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.notConnectedToInternet) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

final class WeatherServiceTests: XCTestCase {
    private let fixed = ShanghaiTime.parseDay("2026-11-16")!.addingTimeInterval(12 * 3600)

    private func payload(_ source: ForecastSource, now: Date, mutate: ((inout [String: Any]) -> Void)? = nil) throws -> Data {
        let start = ShanghaiTime.calendar.startOfDay(for: now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = ShanghaiTime.zone
        formatter.dateFormat = "yyyy-MM-dd"
        let dates = (0..<source.count).map { formatter.string(from: ShanghaiTime.calendar.date(byAdding: .day, value: source.startOffset + $0, to: start)!) }
        var daily: [String: Any] = ["time": dates]
        var units: [String: String] = [:]
        let suffixes = source == .extended ? [""] + (1...50).map { String(format: "_member%02d", $0) } : [""]
        for (member, suffix) in suffixes.enumerated() {
            let h = "temperature_2m_max" + suffix, l = "temperature_2m_min" + suffix
            daily[h] = Array(repeating: 15.0 + Double(member) / 10, count: source.count)
            daily[l] = Array(repeating: 5.0 + Double(member) / 10, count: source.count)
            units[h] = "°C"; units[l] = "°C"
        }
        var json: [String: Any] = ["timezone": "Asia/Shanghai", "daily_units": units, "daily": daily]
        mutate?(&json)
        return try JSONSerialization.data(withJSONObject: json)
    }

    func testRollingMonthRequestAndThirtyDayWindow() throws {
        let url = ForecastSource.rollingMonth.url
        XCTAssertEqual(url.host, "api.open-meteo.com")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first(where: { $0.name == "past_days" })?.value, "15")
        XCTAssertEqual(items.first(where: { $0.name == "forecast_days" })?.value, "15")
        let record = try ForecastDecoder.decode(payload(.rollingMonth, now: fixed), source: .rollingMonth, fetchedAt: fixed)
        XCTAssertTrue(ForecastDecoder.validateCached(record, source: .rollingMonth))
        XCTAssertFalse(ForecastDecoder.validateCached(record, source: .extended))
        let snapshot = record.rollingSnapshot(at: fixed, justFetched: true)
        XCTAssertEqual(snapshot.status, .fresh)
        XCTAssertEqual(snapshot.days.count, 30)
        XCTAssertEqual(snapshot.days[15].date, ShanghaiTime.calendar.startOfDay(for: fixed))
        XCTAssertEqual(ShanghaiTime.label(snapshot.days[0].date), "11/1")
        XCTAssertEqual(ShanghaiTime.label(snapshot.days[29].date), "11/30")
    }

    func testRollingMonthCrossesYearAndRetainsHistoryAfterMidnight() throws {
        let fetched = ShanghaiTime.parseDay("2026-12-31")!.addingTimeInterval(23 * 3600)
        let record = try ForecastDecoder.decode(payload(.rollingMonth, now: fetched), source: .rollingMonth, fetchedAt: fetched)
        let midnight = ShanghaiTime.nextMidnight(after: fetched)
        let initial = record.rollingSnapshot(at: fetched)
        let next = initial.projected(at: midnight)
        XCTAssertEqual(next.days.count, 29)
        XCTAssertEqual(next.days.first?.index, 0)
        XCTAssertEqual(next.days.last?.index, 28)
        XCTAssertEqual(next.days[15].date, midnight)
        XCTAssertEqual(ShanghaiTime.label(next.days.first!.date), "12/17")
        XCTAssertEqual(ShanghaiTime.label(next.days.last!.date), "1/14")
        XCTAssertEqual(next.status, .stale)
        XCTAssertTrue(initial.projected(at: fetched.addingTimeInterval(49 * 3600)).days.isEmpty)
        XCTAssertTrue(initial.projected(at: fetched.addingTimeInterval(-1)).days.isEmpty)
    }

    func testRollingMonthRejectsMissingDuplicateNullAndInvalidTemperatures() throws {
        for change in ["missing", "duplicate", "null", "reversed", "unit", "timezone"] {
            let data = try payload(.rollingMonth, now: fixed) { json in
                var daily = json["daily"] as! [String: Any]
                if change == "missing" || change == "duplicate" {
                    var dates = daily["time"] as! [String]
                    if change == "missing" { dates.removeLast() } else { dates[1] = dates[0] }
                    daily["time"] = dates
                } else if change == "null" {
                    var values = daily["temperature_2m_min"] as! [Any]
                    values[0] = NSNull(); daily["temperature_2m_min"] = values
                } else if change == "reversed" {
                    daily["temperature_2m_min"] = Array(repeating: 30.0, count: 30)
                } else if change == "unit" {
                    var units = json["daily_units"] as! [String: String]
                    units["temperature_2m_min"] = "°F"; json["daily_units"] = units
                } else { json["timezone"] = "GMT" }
                json["daily"] = daily
            }
            XCTAssertThrowsError(try ForecastDecoder.decode(data, source: .rollingMonth, fetchedAt: fixed), change)
        }
    }

    func testRegularCelsiusAndDates() throws {
        let record = try ForecastDecoder.decode(payload(.regular, now: fixed), source: .regular, fetchedAt: fixed)
        XCTAssertEqual(record.days.count, 15)
        XCTAssertEqual(record.days[0].maximum, 15)
        XCTAssertEqual(record.days[0].minimum, 5)
        XCTAssertEqual(ShanghaiTime.label(record.days[14].date), "11/30")
        XCTAssertEqual(record.snapshot(for: .week, at: fixed).days.count, 7)
    }

    func testEnsembleMeanIncludesAll51Members() throws {
        let record = try ForecastDecoder.decode(payload(.extended, now: fixed), source: .extended, fetchedAt: fixed)
        XCTAssertEqual(record.days.count, 30)
        XCTAssertEqual(record.days[0].maximum, 17.5, accuracy: 0.00001)
        XCTAssertEqual(record.days[0].minimum, 7.5, accuracy: 0.00001)
    }

    func testRejectsMissingMemberNullWrongUnitsReversedAndGappedDates() throws {
        let missing = try payload(.extended, now: fixed) { json in
            var daily = json["daily"] as! [String: Any]
            daily.removeValue(forKey: "temperature_2m_min_member50"); json["daily"] = daily
        }
        XCTAssertThrowsError(try ForecastDecoder.decode(missing, source: .extended, fetchedAt: fixed))
        for change in ["null", "unit", "reversed", "gap"] {
            let bad = try payload(.regular, now: fixed) { json in
                var daily = json["daily"] as! [String: Any]
                if change == "null" {
                    var values = daily["temperature_2m_max"] as! [Any]
                    values[3] = NSNull(); daily["temperature_2m_max"] = values
                } else if change == "unit" {
                    var units = json["daily_units"] as! [String: String]
                    units["temperature_2m_max"] = "°F"; json["daily_units"] = units
                } else if change == "reversed" {
                    daily["temperature_2m_min"] = Array(repeating: 30.0, count: 15)
                } else {
                    var dates = daily["time"] as! [String]
                    dates[2] = dates[1]; daily["time"] = dates
                }
                json["daily"] = daily
            }
            XCTAssertThrowsError(try ForecastDecoder.decode(bad, source: .regular, fetchedAt: fixed), change)
        }
    }

    func testShanghaiMidnightTrimsAndNeverInventsMissingDays() throws {
        let fetched = ShanghaiTime.parseDay("2026-11-16")!.addingTimeInterval(23 * 3600)
        let record = try ForecastDecoder.decode(payload(.regular, now: fetched), source: .regular, fetchedAt: fetched)
        let midnight = ShanghaiTime.nextMidnight(after: fetched)
        let snapshot = record.snapshot(for: .fortnight, at: midnight)
        XCTAssertEqual(snapshot.days.count, 14)
        XCTAssertEqual(snapshot.days.first?.date, midnight)
        XCTAssertEqual(snapshot.days.first?.index, 0)
        XCTAssertEqual(snapshot.status, .stale)
        let week = record.snapshot(for: .week, at: fetched).projected(at: midnight)
        XCTAssertEqual(week.days.count, 6)
        XCTAssertEqual(week.status, .stale)
        XCTAssertEqual(WeatherStore.nextRefresh(for: record.snapshot(for: .week, at: fetched), after: fetched), midnight)
    }

    func testExpiredAndFutureDatedCachesAreHidden() throws {
        let record = try ForecastDecoder.decode(payload(.regular, now: fixed), source: .regular, fetchedAt: fixed)
        XCTAssertTrue(record.snapshot(for: .week, at: fixed.addingTimeInterval(49 * 3600)).days.isEmpty)
        XCTAssertTrue(record.snapshot(for: .week, at: fixed.addingTimeInterval(-60)).days.isEmpty)
        XCTAssertFalse(record.isFresh(at: fixed.addingTimeInterval(3 * 3600)))
    }

    private func fixtureStore(_ responder: @escaping (URLRequest) throws -> (Int, Data)) throws -> (WeatherStore, URL, URLSession) {
        StubWeatherProtocol.lock.lock()
        StubWeatherProtocol.responder = responder
        StubWeatherProtocol.count = 0
        StubWeatherProtocol.lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubWeatherProtocol.self]
        let session = URLSession(configuration: config)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (WeatherStore(directory: directory, session: session), directory, session)
    }

    func testHangzhouRollingWindowCoordinatesAndCacheIdentity() throws {
        let url = ForecastSource.hangzhouRollingMonth.url
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(url.host, "api.open-meteo.com")
        for (key, value) in [("latitude", "30.2741"), ("longitude", "120.1551"),
                             ("past_days", "15"), ("forecast_days", "15"),
                             ("temperature_unit", "celsius"), ("timezone", "Asia/Shanghai")] {
            XCTAssertEqual(query.first(where: { $0.name == key })?.value, value)
        }
        let record = try ForecastDecoder.decode(payload(.hangzhouRollingMonth, now: fixed),
            source: .hangzhouRollingMonth, fetchedAt: fixed)
        XCTAssertTrue(ForecastDecoder.validateCached(record, source: .hangzhouRollingMonth))
        XCTAssertFalse(ForecastDecoder.validateCached(record, source: .rollingMonth))
        let snapshot = record.rollingSnapshot(at: fixed)
        XCTAssertEqual(snapshot.days.count, 30)
        XCTAssertEqual(snapshot.days[15].date, ShanghaiTime.calendar.startOfDay(for: fixed))
        let next = snapshot.projected(at: ShanghaiTime.nextMidnight(after: fixed))
        XCTAssertEqual(next.days.count, 29)
        XCTAssertEqual(next.status, .stale)
    }

    func testHangzhouAndShanghaiRequestsAndDiskCachesStaySeparate() async throws {
        let shanghai = try payload(.rollingMonth, now: Date())
        let hangzhou = try payload(.hangzhouRollingMonth, now: Date()) { json in
            var daily = json["daily"] as! [String: Any]
            daily["temperature_2m_max"] = Array(repeating: 25.0, count: 30)
            json["daily"] = daily
        }
        let (store, directory, session) = try fixtureStore { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let latitude = items.first(where: { $0.name == "latitude" })?.value
            return (200, latitude == "30.2741" ? hangzhou : shanghai)
        }
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        async let sh = store.loadRollingMonth()
        async let hz = store.loadHangzhouRollingMonth()
        let (s, h) = await (sh, hz)
        XCTAssertEqual(s.days.first?.maximum, 15)
        XCTAssertEqual(h.days.first?.maximum, 25)
        XCTAssertEqual(StubWeatherProtocol.count, 2)
        for filename in ["rollingMonth.json", "hangzhouRollingMonth.json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(filename).path))
        }
        let reopened = WeatherStore(directory: directory, session: session)
        let disk = await reopened.loadHangzhouRollingMonth()
        XCTAssertEqual(disk.status, .cached)
        XCTAssertEqual(disk.days.first?.maximum, 25)
        XCTAssertEqual(StubWeatherProtocol.count, 2)
    }

    func testHangzhouOfflineKeepsHistoryAndDoesNotUseShanghaiCache() async throws {
        let (store, directory, session) = try fixtureStore { _ in throw URLError(.notConnectedToInternet) }
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let old = Date().addingTimeInterval(-4 * 3600)
        let hz = try ForecastDecoder.decode(payload(.hangzhouRollingMonth, now: old),
            source: .hangzhouRollingMonth, fetchedAt: old)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(hz).write(to: directory.appendingPathComponent("hangzhouRollingMonth.json"))
        let result = await store.loadHangzhouRollingMonth()
        XCTAssertEqual(result.status, .stale)
        XCTAssertEqual(result.fetchedAt, old)
        let today = ShanghaiTime.calendar.startOfDay(for: Date())
        XCTAssertEqual(result.days.filter { $0.date < today }.count, 15)
        XCTAssertTrue(result.days.count == 29 || result.days.count == 30)
        _ = await store.loadHangzhouRollingMonth()
        XCTAssertEqual(StubWeatherProtocol.count, 1)

        // Shanghai still requests its own source and cannot consume Hangzhou data.
        let shanghai = await store.loadRollingMonth()
        XCTAssertEqual(shanghai.status, .unavailable)
        XCTAssertTrue(shanghai.days.isEmpty)
        XCTAssertEqual(StubWeatherProtocol.count, 2)
    }

    func testHangzhouRejectsExpiredCorruptAndWrongCityCaches() async throws {
        for invalid in ["expired", "corrupt", "wrongCity"] {
            let (store, directory, session) = try fixtureStore { _ in (503, Data("{}".utf8)) }
            defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("hangzhouRollingMonth.json")
            if invalid == "corrupt" {
                try Data("broken".utf8).write(to: file)
            } else {
                let source: ForecastSource = invalid == "wrongCity" ? .rollingMonth : .hangzhouRollingMonth
                let fetched = invalid == "expired" ? Date().addingTimeInterval(-49 * 3600) : Date()
                let record = try ForecastDecoder.decode(payload(source, now: fetched), source: source, fetchedAt: fetched)
                try JSONEncoder().encode(record).write(to: file)
            }
            let result = await store.loadHangzhouRollingMonth()
            XCTAssertEqual(result.status, .unavailable, invalid)
            XCTAssertTrue(result.days.isEmpty, invalid)
            _ = await store.loadHangzhouRollingMonth()
            XCTAssertEqual(StubWeatherProtocol.count, 1, invalid)
        }
    }

    func testHangzhouConcurrentRequestsShareOneFetch() async throws {
        let body = try payload(.hangzhouRollingMonth, now: Date())
        let (store, directory, session) = try fixtureStore { _ in (200, body) }
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        async let first = store.loadHangzhouRollingMonth()
        async let second = store.loadHangzhouRollingMonth()
        let (a, b) = await (first, second)
        XCTAssertEqual(a.days.count, 30)
        XCTAssertEqual(b.days.count, 30)
        XCTAssertEqual(StubWeatherProtocol.count, 1)
    }

    func testRollingRequestsShareTaskPersistAndReloadFromDisk() async throws {
        let body = try payload(.rollingMonth, now: Date())
        let (store, directory, session) = try fixtureStore { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(items.first(where: { $0.name == "past_days" })?.value, "15")
            return (200, body)
        }
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        async let first = store.loadRollingMonth()
        async let second = store.loadRollingMonth()
        let (a, b) = await (first, second)
        XCTAssertEqual(a.days.count, 30)
        XCTAssertEqual(b.days.count, 30)
        XCTAssertEqual(a.status, .fresh)
        XCTAssertEqual(StubWeatherProtocol.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("rollingMonth.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("regular.json").path))
        let reopened = WeatherStore(directory: directory, session: session)
        let disk = await reopened.loadRollingMonth()
        XCTAssertEqual(disk.status, .cached)
        XCTAssertEqual(disk.days.count, 30)
        XCTAssertEqual(StubWeatherProtocol.count, 1)
    }

    func testRollingOfflineRetainsPastDatesAndThrottlesRetries() async throws {
        let (store, directory, session) = try fixtureStore { _ in throw URLError(.notConnectedToInternet) }
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let old = Date().addingTimeInterval(-4 * 3600)
        let record = try ForecastDecoder.decode(payload(.rollingMonth, now: old), source: .rollingMonth, fetchedAt: old)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("rollingMonth.json"))
        let result = await store.loadRollingMonth()
        XCTAssertEqual(result.status, .stale)
        XCTAssertEqual(result.fetchedAt, old)
        let today = ShanghaiTime.calendar.startOfDay(for: Date())
        XCTAssertEqual(result.days.filter { $0.date < today }.count, 15)
        XCTAssertTrue(result.days.count == 29 || result.days.count == 30)
        _ = await store.loadRollingMonth()
        XCTAssertEqual(StubWeatherProtocol.count, 1)
    }

    func testRollingExpiredCacheAndHTTPFailureShowUnavailable() async throws {
        let (store, directory, session) = try fixtureStore { _ in (429, Data("{}".utf8)) }
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let old = Date().addingTimeInterval(-49 * 3600)
        let record = try ForecastDecoder.decode(payload(.rollingMonth, now: old), source: .rollingMonth, fetchedAt: old)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("rollingMonth.json"))
        let result = await store.loadRollingMonth()
        XCTAssertEqual(result.status, .unavailable)
        XCTAssertTrue(result.days.isEmpty)
        _ = await store.loadRollingMonth()
        XCTAssertEqual(StubWeatherProtocol.count, 1)
    }

    func testRollingRefreshUsesThreeHoursMidnightAndFailureRetry() {
        let fresh = RollingTemperatureSnapshot(days: [], status: .fresh, fetchedAt: fixed)
        XCTAssertEqual(WeatherStore.nextRefresh(for: fresh, after: fixed), fixed.addingTimeInterval(3 * 3600))
        let late = ShanghaiTime.parseDay("2026-11-16")!.addingTimeInterval(23 * 3600)
        let evening = RollingTemperatureSnapshot(days: [], status: .fresh, fetchedAt: late)
        XCTAssertEqual(WeatherStore.nextRefresh(for: evening, after: late), ShanghaiTime.nextMidnight(after: late))
        let unavailable = RollingTemperatureSnapshot(days: [], status: .unavailable, fetchedAt: nil)
        XCTAssertEqual(WeatherStore.nextRefresh(for: unavailable, after: fixed), fixed.addingTimeInterval(30 * 60))
    }

    func testConcurrentSevenAndFifteenShareRequestAndPersist() async throws {
        let body = try payload(.regular, now: Date())
        let (store, directory, session) = try fixtureStore { request in
            XCTAssertEqual(request.url?.host, "api.open-meteo.com")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(items.first(where: { $0.name == "forecast_days" })?.value, "15")
            return (200, body)
        }
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        async let week = store.load(.week)
        async let fortnight = store.load(.fortnight)
        let (w, f) = await (week, fortnight)
        XCTAssertEqual(w.days.count, 7); XCTAssertEqual(f.days.count, 15)
        XCTAssertFalse(w.isSample)
        XCTAssertEqual(StubWeatherProtocol.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("regular.json").path))
        let cached = await store.load(.week)
        XCTAssertEqual(cached.status, .cached)
        XCTAssertEqual(StubWeatherProtocol.count, 1)
    }

    func testOfflineUsesDiskCacheAndThrottlesFailures() async throws {
        let (store, directory, session) = try fixtureStore { _ in throw URLError(.notConnectedToInternet) }
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        // Keep this on the same day and make its age exceed the refresh interval.
        let now = Date()
        let old = now.addingTimeInterval(-4 * 3600)
        let record = try ForecastDecoder.decode(payload(.regular, now: old), source: .regular, fetchedAt: old)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("regular.json"))
        let result = await store.load(.week)
        XCTAssertFalse(result.days.isEmpty)
        XCTAssertEqual(result.status, .stale)
        XCTAssertEqual(result.fetchedAt, old)
        _ = await store.load(.fortnight)
        XCTAssertEqual(StubWeatherProtocol.count, 1)
    }

    func testHTTPErrorAndCorruptCacheDoNotBecomeFakeForecasts() async throws {
        let (store, directory, session) = try fixtureStore { _ in (429, Data("{}".utf8)) }
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("regular.json"))
        let result = await store.load(.week)
        XCTAssertTrue(result.days.isEmpty)
        XCTAssertEqual(result.status, .unavailable)
        XCTAssertNil(result.fetchedAt)
        XCTAssertFalse(result.isSample)
    }
}

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
        let dates = (0..<source.count).map { formatter.string(from: ShanghaiTime.calendar.date(byAdding: .day, value: $0, to: start)!) }
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

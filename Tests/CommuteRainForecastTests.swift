import XCTest
import Foundation
@testable import WeatherCore

final class CommuteRainForecastTests: XCTestCase {
    private let fixed = ShanghaiTime.parseDay("2026-11-20")!.addingTimeInterval(12 * 3600)

    private func record(at date: Date, amounts: [Int: Double] = [:], showers: [Int: Double] = [:],
                        snow: [Int: Double] = [:], codes: [Int: Int] = [:],
                        missing: Set<Int> = []) -> CommuteRainRecord {
        let start = ShanghaiTime.calendar.startOfDay(for: date)
        let hours = (0..<72).map { index in
            CommuteRainHour(date: start.addingTimeInterval(Double(index) * 3600),
                rain: missing.contains(index) ? nil : amounts[index] ?? 0,
                showers: showers[index] ?? 0, snowfall: snow[index] ?? 0,
                weatherCode: codes[index] ?? 0)
        }
        return CommuteRainRecord(schema: 1, source: CommuteRainRecord.source, fetchedAt: date, hours: hours)
    }

    private func fixture(_ handler: @escaping (URLRequest) throws -> (Int, Data)) -> URLSession {
        StubWeatherProtocol.lock.lock()
        StubWeatherProtocol.responder = handler
        StubWeatherProtocol.count = 0
        StubWeatherProtocol.lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubWeatherProtocol.self]
        return URLSession(configuration: config)
    }

    private func requestCount() -> Int {
        StubWeatherProtocol.lock.lock()
        defer { StubWeatherProtocol.lock.unlock() }
        return StubWeatherProtocol.count
    }

    private func payload() throws -> Data {
        let saved = record(at: fixed, amounts: [33: 1, 45: 8])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = ShanghaiTime.zone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return try JSONSerialization.data(withJSONObject: [
            "latitude": 31.247803, "longitude": 121.5, "timezone": "Asia/Shanghai",
            "hourly_units": ["time": "iso8601", "rain": "mm", "showers": "mm",
                             "snowfall": "cm", "weather_code": "wmo code"],
            "hourly": ["time": saved.hours.map { formatter.string(from: $0.date) },
                       "rain": saved.hours.map { $0.rain! },
                       "showers": saved.hours.map { $0.showers! },
                       "snowfall": saved.hours.map { $0.snowfall! },
                       "weather_code": saved.hours.map { $0.weatherCode! }]
        ])
    }

    func testIntensityBoundaries() {
        let cases: [(Double, CommuteRainIntensity)] = [
            (0, .none), (0.01, .light), (2.49, .light),
            (2.5, .moderate), (7.99, .moderate), (8, .heavy)
        ]
        for (amount, expected) in cases {
            XCTAssertEqual(CommuteRainIntensity(millimetres: amount), expected)
        }
    }

    func testAllMessageCombinations() {
        let levels: [CommuteRainIntensity] = [.none, .light, .moderate, .heavy]
        for morning in levels {
            for evening in levels {
                let result = CommuteRainRecord.message(morning: morning, evening: evening)
                if morning == .none && evening == .none { XCTAssertNil(result) }
                else if morning == .none { XCTAssertEqual(result, "明天下班有" + evening.label) }
                else if evening == .none { XCTAssertEqual(result, "明天上班有" + morning.label) }
                else if morning == evening { XCTAssertEqual(result, "明天上下班有" + morning.label) }
                else { XCTAssertEqual(result, "明天上班" + morning.label + "，下班" + evening.label) }
            }
        }
    }

    func testPrecedingHourWindowsAndShowers() {
        XCTAssertEqual(record(at: fixed, amounts: [33: 0.1]).message(at: fixed), "明天上班有小雨")
        XCTAssertEqual(record(at: fixed, amounts: [34: 2.5]).message(at: fixed), "明天上班有中雨")
        XCTAssertEqual(record(at: fixed, showers: [44: 8]).message(at: fixed), "明天下班有大雨")
        XCTAssertEqual(record(at: fixed, amounts: [33: 1, 34: 3, 45: 8]).message(at: fixed),
                       "明天上班中雨，下班大雨")
        XCTAssertNil(record(at: fixed, amounts: [32: 8, 35: 8, 43: 8, 46: 8]).message(at: fixed))
        XCTAssertTrue(record(at: fixed).hasCompleteCoverage(at: fixed))
        XCTAssertNil(record(at: fixed).message(at: fixed))
    }

    func testMissingFrozenSnowAndHailHideMessage() {
        XCTAssertFalse(record(at: fixed, missing: [45]).hasCompleteCoverage(at: fixed))
        XCTAssertNil(record(at: fixed, amounts: [33: 1], missing: [45]).message(at: fixed))
        XCTAssertNil(record(at: fixed, amounts: [33: 1], snow: [33: 0.1]).message(at: fixed))
        for code in [56, 57, 66, 67, 71, 73, 75, 77, 85, 86, 96, 99] {
            XCTAssertNil(record(at: fixed, amounts: [33: 1], codes: [33: code]).message(at: fixed))
        }
    }

    func testMidnightRetargetsTomorrowAndExpiryHidesMessage() {
        let late = ShanghaiTime.parseDay("2026-12-31")!.addingTimeInterval(23 * 3600)
        let saved = record(at: late, amounts: [33: 1, 57: 8])
        XCTAssertEqual(saved.message(at: late), "明天上班有小雨")
        XCTAssertEqual(saved.message(at: ShanghaiTime.nextMidnight(after: late)), "明天上班有大雨")
        XCTAssertNil(saved.message(at: late.addingTimeInterval(-1)))
        XCTAssertNil(saved.message(at: late.addingTimeInterval(3 * 3600)))
    }

    func testInvalidRecordsAreHidden() {
        let valid = record(at: fixed, amounts: [33: 1])
        XCTAssertTrue(CommuteRainDecoder.validate(valid))
        XCTAssertNil(record(at: fixed, amounts: [33: -1]).message(at: fixed))
        XCTAssertNil(record(at: fixed, amounts: [33: .infinity]).message(at: fixed))
        let wrong = CommuteRainRecord(schema: 2, source: valid.source, fetchedAt: fixed, hours: valid.hours)
        XCTAssertNil(wrong.message(at: fixed))
        let reversed = CommuteRainRecord(schema: 1, source: valid.source,
                                         fetchedAt: fixed, hours: Array(valid.hours.reversed()))
        XCTAssertFalse(CommuteRainDecoder.validate(reversed))
    }

    func testDecodeAndRequestConfiguration() throws {
        let decoded = try CommuteRainDecoder.decode(payload(), fetchedAt: fixed)
        XCTAssertEqual(decoded.message(at: fixed), "明天上班小雨，下班大雨")
        let items = URLComponents(url: CommuteRainDecoder.url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "timezone" }?.value, "Asia/Shanghai")
        XCTAssertEqual(items.first { $0.name == "forecast_days" }?.value, "3")
        XCTAssertEqual(items.first { $0.name == "precipitation_unit" }?.value, "mm")
        XCTAssertEqual(items.first { $0.name == "latitude" }?.value, "31.2304")
        for mutate in ["units", "duplicate", "missing", "negative", "wrongCity"] {
            var json = try JSONSerialization.jsonObject(with: payload()) as! [String: Any]
            var hourly = json["hourly"] as! [String: Any]
            if mutate == "units" {
                var units = json["hourly_units"] as! [String: String]
                units["rain"] = "inch"; json["hourly_units"] = units
            } else if mutate == "duplicate" {
                var times = hourly["time"] as! [String]
                times[34] = times[33]; hourly["time"] = times
            } else if mutate == "missing" {
                hourly["showers"] = [0.0]
            } else if mutate == "negative" {
                var rain = hourly["rain"] as! [Double]
                rain[33] = -1; hourly["rain"] = rain
            } else { json["latitude"] = 0 }
            json["hourly"] = hourly
            XCTAssertThrowsError(try CommuteRainDecoder.decode(
                JSONSerialization.data(withJSONObject: json), fetchedAt: fixed), mutate)
        }
    }

    func testConcurrentLoadsPersistAndReloadWithoutNetwork() async throws {
        let data = try payload()
        let session = fixture { _ in (200, data) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let store = CommuteRainStore(directory: directory, session: session)
        async let first = store.load(now: fixed)
        async let second = store.load(now: fixed)
        let (a, b) = await (first, second)
        XCTAssertEqual(a.record?.message(at: fixed), "明天上班小雨，下班大雨")
        XCTAssertEqual(b.record?.message(at: fixed), a.record?.message(at: fixed))
        XCTAssertEqual(requestCount(), 1)
        let reloaded = CommuteRainStore(directory: directory, session: session)
        let cached = await reloaded.load(now: fixed.addingTimeInterval(60))
        XCTAssertNotNil(cached.record)
        XCTAssertEqual(requestCount(), 1)
    }

    func testHTTPFailureIsHiddenAndThrottled() async {
        let session = fixture { _ in (503, Data()) }
        defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = CommuteRainStore(directory: directory, session: session)
        let first = await store.load(now: fixed)
        let second = await store.load(now: fixed.addingTimeInterval(60))
        XCTAssertNil(first.record); XCTAssertNil(second.record)
        XCTAssertEqual(first.refreshAfter, fixed.addingTimeInterval(15 * 60))
        XCTAssertEqual(requestCount(), 1)
    }

    func testIncompleteForecastRetriesAndDiskFailureKeepsMemory() async throws {
        var json = try JSONSerialization.jsonObject(with: payload()) as! [String: Any]
        var hourly = json["hourly"] as! [String: Any]
        var rain = hourly["rain"] as! [Any]
        rain[45] = NSNull(); hourly["rain"] = rain; json["hourly"] = hourly
        let data = try JSONSerialization.data(withJSONObject: json)
        let session = fixture { _ in (200, data) }
        defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CommuteRainStore(directory: directory, session: session)
        let first = await store.load(now: fixed)
        XCTAssertNil(first.record?.message(at: fixed))
        XCTAssertEqual(first.refreshAfter, fixed.addingTimeInterval(15 * 60))
        _ = await store.load(now: fixed.addingTimeInterval(60))
        XCTAssertEqual(requestCount(), 1)
    }

    func testWriteFailureKeepsSuccessfulForecastInMemory() async throws {
        let data = try payload()
        let session = fixture { _ in (200, data) }
        defer { session.invalidateAndCancel() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = CommuteRainStore(directory: file, session: session)
        let first = await store.load(now: fixed)
        XCTAssertEqual(first.record?.message(at: fixed), "明天上班小雨，下班大雨")
        _ = await store.load(now: fixed.addingTimeInterval(60))
        XCTAssertEqual(requestCount(), 1)
    }
}

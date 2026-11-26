import Foundation
import XCTest
@testable import WeatherCore

final class YangpuTideTests: XCTestCase {
    private func time(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        ShanghaiTime.calendar.date(from: DateComponents(
            year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private var fullForecast: [TideReading] {
        [
            .init(date: time(25, 22), level: 1.1),
            .init(date: time(26, 2, 20), level: 3.2),
            .init(date: time(26, 8, 15), level: 0.5),
            .init(date: time(26, 15), level: 5.0),
            .init(date: time(26, 21, 20), level: 0.7),
            .init(date: time(27, 2), level: 4.2),
            .init(date: time(27, 9), level: 1.2),
        ]
    }

    func testDisplayUsesNextHighWhenRisingAndNextLowWhenFalling() {
        var snapshot = YangpuTideSnapshot(forecasts: fullForecast)
        snapshot.updateObservations([
            .init(date: time(26, 14, 45), level: 1.1),
            .init(date: time(26, 14, 50), level: 1.3),
        ], now: time(26, 14, 53))
        XCTAssertEqual(snapshot.line(at: time(26, 14, 53)),
                       "杨浦滨江 · 涨潮 · 1.3 / 5.0 m 15:00")

        snapshot.updateObservations([
            .init(date: time(26, 15, 30), level: 4.4),
            .init(date: time(26, 15, 35), level: 4.2),
        ], now: time(26, 15, 36))
        XCTAssertEqual(snapshot.line(at: time(26, 15, 36)),
                       "杨浦滨江 · 退潮 · 4.2 / 5.0 m 21:20")
        XCTAssertNil(snapshot.line(at: time(26, 16, 6)))
    }

    func testRollingForecastRetainsEarlierHighAndRequiresCoverage() {
        let observationTime = time(26, 16)
        let observations = [
            TideReading(date: time(26, 15, 55), level: 4.2),
            TideReading(date: observationTime, level: 4.1),
        ]
        let evening = Array(fullForecast.dropFirst(4))
        var snapshot = YangpuTideSnapshot(observations: observations, forecasts: evening)
        XCTAssertNil(snapshot.line(at: observationTime))

        snapshot.forecasts = fullForecast
        snapshot.updateForecasts(evening, now: observationTime)
        XCTAssertEqual(snapshot.line(at: observationTime),
                       "杨浦滨江 · 退潮 · 4.1 / 5.0 m 21:20")
        snapshot.observations = [observations[1]]
        XCTAssertNil(snapshot.line(at: observationTime))
    }

    func testReadOnlyHuangpuParkAndIgnoreInvalidHeight() throws {
        let response = Data("""
        {"code":200,"data":[
          {"STATIONID":"SW63401500","DATETIME":"2026-11-26 14:15:00","OUTWATER":"3.83"},
          {"STATIONID":"SW63401750","DATETIME":"2026-11-26 14:15:00","OUTWATER":"3.99"},
          {"STATIONID":"SW63401500","DATETIME":"2026-11-26 14:10:00","OUTWATER":"null"}
        ]}
        """.utf8)
        let readings = try XCTUnwrap(YangpuTideStore.parse(response, levelField: "OUTWATER"))
        XCTAssertEqual(readings.count, 1)
        XCTAssertEqual(readings.first?.date, time(26, 14, 15))
        XCTAssertEqual(readings.first?.level, 3.83)
    }
}

import XCTest
import Foundation
@testable import WeatherCore

final class AircraftServiceTests: XCTestCase {
    private let bounds = AircraftBounds(west: 116, south: 27, east: 124, north: 36)
    private let now = Date(timeIntervalSince1970: 1_795_247_422)

    private func payload(age: Double = 3, grounded: Bool = false,
                         category: Int = 8, track: Any = 343.98) throws -> Data {
        let row: [Any] = ["7804c3", "CES2631 ", "China",
            now.timeIntervalSince1970 - age, now.timeIntervalSince1970,
            118.8173, 32.149, 7802.88, grounded, 169.67, track, 0,
            NSNull(), 7879.08, "6240", false, 0, category]
        return try JSONSerialization.data(withJSONObject: [
            "time": now.timeIntervalSince1970, "states": [row]])
    }

    func testRealResponseFieldsAndExpiry() throws {
        let record = try AircraftDecoder.decode(payload(), bounds: bounds, now: now)
        let state = try XCTUnwrap(record.states.first)
        XCTAssertEqual(state.icao24, "7804c3")
        XCTAssertEqual(state.callsign, "CES2631")
        XCTAssertEqual(state.category, 8)
        XCTAssertEqual(try XCTUnwrap(state.track), 343.98, accuracy: 0.001)
        XCTAssertEqual(record.visible(at: now.addingTimeInterval(296)).count, 1)
        XCTAssertTrue(record.visible(at: now.addingTimeInterval(297)).isEmpty)
    }

    func testOldGroundedAndFuturePositionsAreHidden() throws {
        for age in [300.0, 301.0, -1.0] {
            XCTAssertTrue(try AircraftDecoder.decode(payload(age: age),
                bounds: bounds, now: now).states.isEmpty)
        }
        XCTAssertTrue(try AircraftDecoder.decode(payload(grounded: true),
            bounds: bounds, now: now).states.isEmpty)
    }

    private func state(id: Int, age: TimeInterval) -> AircraftState {
        AircraftState(
            icao24: String(format: "%06x", id),
            callsign: nil,
            positionAt: now.addingTimeInterval(-age),
            longitude: 118.8173,
            latitude: 32.149,
            track: nil,
            category: 0
        )
    }

    func testDecoderKeepsOldPositionsWithinFiveMinutes() throws {
        for age in [120.0, 230.0, 299.0] {
            let record = try AircraftDecoder.decode(
                payload(age: age), bounds: bounds, now: now)
            XCTAssertEqual(record.states.count, 1)
            XCTAssertEqual(record.visible(at: now).count, 1)
            XCTAssertEqual(
                try XCTUnwrap(record.states.first).positionAt,
                now.addingTimeInterval(-age)
            )
        }
    }

    func testFiveOldAircraftRemainVisibleButSixAreHidden() {
        let five = (1...5).map { state(id: $0, age: 230) }
        XCTAssertEqual(
            AircraftDisplayPolicy.choose(five, at: now, bounds: bounds).count, 5)
        XCTAssertTrue(
            AircraftDisplayPolicy.choose(
                five + [state(id: 6, age: 230)],
                at: now, bounds: bounds
            ).isEmpty
        )
    }

    func testFreshPositionsReplaceOldPositions() {
        let old = (1...5).map { state(id: $0, age: 120) }
        let fresh = state(id: 6, age: 119)
        let selected = AircraftDisplayPolicy.choose(
            old + [fresh], at: now, bounds: bounds)
        XCTAssertEqual(selected.map { $0.icao24 }, [fresh.icao24])
    }

    func testFiveMinuteExpiryBoundary() {
        let aircraft = state(id: 1, age: 299)
        XCTAssertEqual(
            AircraftDisplayPolicy.choose(
                [aircraft], at: now, bounds: bounds).count, 1)
        XCTAssertTrue(
            AircraftDisplayPolicy.choose(
                [aircraft], at: now.addingTimeInterval(1), bounds: bounds
            ).isEmpty
        )
    }

    func testMissingHeadingAndUnknownCategoryRemainUsable() throws {
        let record = try AircraftDecoder.decode(payload(category: 0, track: NSNull()),
            bounds: bounds, now: now)
        XCTAssertEqual(record.states.count, 1)
        XCTAssertNil(record.states.first?.track)
        XCTAssertEqual(record.states.first?.category, 0)
    }

    func testNullStatesAndBoundingBoxRequest() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "time": now.timeIntervalSince1970, "states": NSNull()])
        XCTAssertTrue(try AircraftDecoder.decode(data, bounds: bounds, now: now).states.isEmpty)
        let url = try AircraftDecoder.url(bounds: bounds)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(url.host, "opensky-network.org")
        XCTAssertEqual(items.first { $0.name == "extended" }?.value, "1")
        XCTAssertEqual(items.first { $0.name == "lomin" }?.value, "116.0")
    }
}

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
        XCTAssertEqual(record.visible(at: now.addingTimeInterval(116)).count, 1)
        XCTAssertTrue(record.visible(at: now.addingTimeInterval(117)).isEmpty)
    }

    func testOldGroundedAndFuturePositionsAreHidden() throws {
        for age in [120.0, 230.0, -1.0] {
            XCTAssertTrue(try AircraftDecoder.decode(payload(age: age),
                bounds: bounds, now: now).states.isEmpty)
        }
        XCTAssertTrue(try AircraftDecoder.decode(payload(grounded: true),
            bounds: bounds, now: now).states.isEmpty)
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

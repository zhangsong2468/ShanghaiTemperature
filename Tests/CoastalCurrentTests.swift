import XCTest
import Foundation
@testable import WeatherCore

private final class CoastalTestClock {
    private let lock=NSLock()
    private var value=Date(timeIntervalSince1970:1_795_740_000)
    func now() -> Date { lock.lock();defer { lock.unlock() };return value }
    func advance(_ seconds: TimeInterval) { lock.lock();value=value.addingTimeInterval(seconds);lock.unlock() }
}

final class CoastalCurrentTests: XCTestCase {
    private func payload(at date: Date,mutate: ((inout [[String:Any]]) -> Void)? = nil) throws -> Data {
        var rows=CoastalCurrentPoint.coast.enumerated().map { index,point -> [String:Any] in
            ["latitude":point.latitude,"longitude":point.longitude,
             "current_units":["time":"unixtime","ocean_current_velocity":"m/s","ocean_current_direction":"°"],
             "current":["time":date.timeIntervalSince1970,"ocean_current_velocity":0.5,
                        "ocean_current_direction":Double(index%4)*90]]
        }
        mutate?(&rows)
        return try JSONSerialization.data(withJSONObject:rows)
    }

    private func fixture(clock: CoastalTestClock,status: Int = 200) throws -> (CoastalCurrentStore,URL,URLSession) {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        StubWeatherProtocol.lock.lock()
        StubWeatherProtocol.count=0
        StubWeatherProtocol.responder={ request in
            XCTAssertEqual(request.url?.host,"marine-api.open-meteo.com")
            return (status,try self.payload(at:clock.now()))
        }
        StubWeatherProtocol.lock.unlock()
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[StubWeatherProtocol.self]
        let session=URLSession(configuration:config)
        return (CoastalCurrentStore(directory:directory,session:session,clock:{clock.now()}),directory,session)
    }

    func testRequestUsesInstantCurrentAndFiveIndependentSeaPoints() {
        let items=URLComponents(url:CoastalCurrentDecoder.request(),resolvingAgainstBaseURL:false)!.queryItems!
        let query=Dictionary(uniqueKeysWithValues:items.map {($0.name,$0.value!)})
        XCTAssertEqual(query["current"],"ocean_current_velocity,ocean_current_direction")
        XCTAssertNil(query["hourly"])
        XCTAssertEqual(query["wind_speed_unit"],"ms")
        XCTAssertEqual(query["cell_selection"],"sea")
        XCTAssertEqual(query["latitude"]!.split(separator:",").count,5)
    }

    func testDirectionMeansHeadingToRatherThanComingFrom() throws {
        let date=CoastalTestClock().now()
        let rows=try CoastalCurrentDecoder.decode(payload(at:date),at:date)
        XCTAssertEqual(rows.count,5)
        XCTAssertEqual(rows[0].northwardUnit,1,accuracy:1e-9)
        XCTAssertEqual(rows[1].eastwardUnit,1,accuracy:1e-9)
        XCTAssertEqual(rows[2].northwardUnit,-1,accuracy:1e-9)
        XCTAssertEqual(rows[3].eastwardUnit,-1,accuracy:1e-9)
    }

    func testRejectsWrongUnitsCoordinatesAndResponseCount() throws {
        let date=CoastalTestClock().now()
        for kind in ["units","coordinates","count"] {
            let data=try payload(at:date) { rows in
                if kind=="units" { rows[0]["current_units"]=["time":"unixtime","ocean_current_velocity":"km/h","ocean_current_direction":"°"] }
                if kind=="coordinates" { rows[0]["latitude"]=0 }
                if kind=="count" { rows.removeLast() }
            }
            XCTAssertThrowsError(try CoastalCurrentDecoder.decode(data,at:date))
        }
    }

    func testNullMissingAndOldPointsAreNotInvented() throws {
        let date=CoastalTestClock().now()
        let data=try payload(at:date) { rows in
            var missing=rows[0]["current"] as! [String:Any]
            missing["ocean_current_velocity"]=NSNull();rows[0]["current"]=missing
            var old=rows[1]["current"] as! [String:Any]
            old["time"]=date.addingTimeInterval(-3601).timeIntervalSince1970;rows[1]["current"]=old
        }
        XCTAssertEqual(try CoastalCurrentDecoder.decode(data,at:date).count,3)
        XCTAssertThrowsError(try CoastalCurrentDecoder.decode(payload(at:date.addingTimeInterval(60)),at:date))
    }

    func testExpiresAtTwoMinutesEvenWhenReusedByLaterEntries() throws {
        let date=CoastalTestClock().now()
        let overlay=CoastalCurrentOverlay(fetchedAt:date,samples:try CoastalCurrentDecoder.decode(payload(at:date),at:date))
        XCTAssertEqual(overlay.visible(at:date).count,5)
        XCTAssertEqual(overlay.visible(at:date.addingTimeInterval(119)).count,5)
        XCTAssertTrue(overlay.visible(at:date.addingTimeInterval(120)).isEmpty)
        XCTAssertTrue(overlay.visible(at:date.addingTimeInterval(-1)).isEmpty)
    }

    func testCachedReadAndProcessRestartDoNotExtendVisibilityOrRequestEarly() async throws {
        let clock=CoastalTestClock()
        let (store,directory,session)=try fixture(clock:clock)
        defer { session.invalidateAndCancel();try? FileManager.default.removeItem(at:directory) }
        let first=await store.load()
        let fetched=try XCTUnwrap(first.overlay).fetchedAt
        clock.advance(121)
        let cached=await store.load()
        XCTAssertEqual(cached.overlay?.fetchedAt,fetched)
        XCTAssertTrue(cached.overlay!.visible(at:clock.now()).isEmpty)
        let restarted=CoastalCurrentStore(directory:directory,session:session,clock:{clock.now()})
        let persisted=await restarted.load()
        XCTAssertEqual(persisted.overlay?.fetchedAt,fetched)
        XCTAssertEqual(StubWeatherProtocol.count,1)
        clock.advance(479)
        let next=await restarted.load()
        XCTAssertEqual(next.overlay?.fetchedAt,clock.now())
        XCTAssertEqual(StubWeatherProtocol.count,2)
    }

    func testOverlappingLoadsShareOneNetworkRequest() async throws {
        let clock=CoastalTestClock()
        let (store,directory,session)=try fixture(clock:clock)
        defer { session.invalidateAndCancel();try? FileManager.default.removeItem(at:directory) }
        async let first=store.load()
        async let second=store.load()
        let results=await (first,second)
        XCTAssertNotNil(results.0.overlay);XCTAssertNotNil(results.1.overlay)
        XCTAssertEqual(StubWeatherProtocol.count,1)
    }

    func testRateLimitHidesOverlayAndBacksOffForTenMinutes() async throws {
        let clock=CoastalTestClock()
        let (store,directory,session)=try fixture(clock:clock,status:429)
        defer { session.invalidateAndCancel();try? FileManager.default.removeItem(at:directory) }
        let result=await store.load()
        XCTAssertNil(result.overlay)
        XCTAssertGreaterThanOrEqual(result.refreshAfter.timeIntervalSince(clock.now()),600)
        // Before the deadline, retry remains suppressed.
        clock.advance(599)
        let cached=await store.load()
        XCTAssertNil(cached.overlay)
        XCTAssertEqual(StubWeatherProtocol.count,1)
        // Exactly at ten minutes, a new attempt is allowed. A second 429
        // still hides the overlay and establishes a new ten-minute deadline.
        clock.advance(1)
        let retried=await store.load()
        XCTAssertNil(retried.overlay)
        XCTAssertEqual(StubWeatherProtocol.count,2)
        XCTAssertGreaterThanOrEqual(retried.refreshAfter.timeIntervalSince(clock.now()),600)
    }
}

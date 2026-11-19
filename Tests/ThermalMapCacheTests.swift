import XCTest
import Foundation
@testable import WeatherCore

final class ThermalMapCacheTests: XCTestCase {
    private func record(at date: Date) -> ThermalMapCacheRecord {
        let points=[ThermalBandPoint(id:"a",latitude:31,longitude:120,apparentTemperature:10,bandIndex:0),
                    ThermalBandPoint(id:"b",latitude:32,longitude:121,apparentTemperature:11,bandIndex:0)]
        let snapshot=ThermalBandSnapshot(algorithmVersion:2,source:.local,date:date,
            bands:[ThermalBand(index:0,lower:10,upper:11,representative:10.5,pointCount:2)],cuts:[],baseCuts:[],points:points,
            historicalSpatialError:1,selectedNeighbourCount:1,criterionScore:0,retainedPreviousCuts:false)
        return ThermalMapCacheRecord(schema:1,fetchedAt:date,snapshot:snapshot,anomalyMessage:"接近往年同期均值",seasonalMessage:nil)
    }
    func testCacheDoesNotCrossSourcesOrPretendFutureDataIsFresh() {
        let date=ShanghaiTime.parseDay("2026-11-19")!
        let cached=record(at:date)
        XCTAssertTrue(cached.isValid(source:.local,at:date))
        XCTAssertFalse(cached.isValid(source:.network,at:date))
        XCTAssertFalse(cached.isValid(source:.local,at:date.addingTimeInterval(-1)))
        XCTAssertFalse(cached.isValid(source:.local,at:date.addingTimeInterval(49*3600)))
        XCTAssertFalse(cached.isFresh(at:date.addingTimeInterval(3600)))
    }
    func testStoreUsesFreshDiskCacheWithoutNetworkOrBundleLookup() async throws {
        let date=ShanghaiTime.parseDay("2026-11-19")!
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try JSONEncoder().encode(record(at:date)).write(to:directory.appendingPathComponent("map-local.json"))
        let store=RegionalThermalStore(directory:directory,sourceProvider:{.local})
        let result=await store.load(now:date.addingTimeInterval(600))
        XCTAssertEqual(result.display.snapshot?.source,.local)
        XCTAssertEqual(result.display.snapshot?.points.count,2)
        XCTAssertEqual(result.refreshAfter,date.addingTimeInterval(3600))
    }

    func testMidnightUpdatesCalendarWithoutChangingDataTimestamp() {
        let fetched=ShanghaiTime.parseDay("2026-11-21")!.addingTimeInterval(23*3600)
        let record=record(at:fetched)
        let midnight=ShanghaiTime.nextMidnight(after:fetched)
        let update=ThermalMapUpdate(display:record.display(at:fetched),refreshAfter:midnight,record:record)
        let future=update.projected(at:midnight)
        XCTAssertEqual(SolarTermCalendar.status(at:future.date).label,"小雪")
        XCTAssertEqual(future.snapshot?.date,fetched)
        XCTAssertTrue(future.message.contains("旧缓存"))
        XCTAssertNil(update.projected(at:fetched.addingTimeInterval(49*3600)).snapshot)
    }
}

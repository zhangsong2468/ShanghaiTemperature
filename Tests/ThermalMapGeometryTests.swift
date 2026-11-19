import XCTest
import Foundation
@testable import WeatherCore

final class ThermalMapGeometryTests: XCTestCase {
    func testPolygonHolesAreNotFilled() {
        let outer=[[0.0,0],[4,0],[4,4],[0,4],[0,0]]
        let hole=[[1.0,1],[2,1],[2,2],[1,2],[1,1]]
        let region=ThermalMapGeometry.Region(name:"test",polygons:[[outer,hole]])
        let geometry=ThermalMapGeometry(schema:1,regions:[region],bounds:[0,0,4,4],labels:[])
        XCTAssertTrue(geometry.contains(longitude:0.5,latitude:0.5))
        XCTAssertFalse(geometry.contains(longitude:1.5,latitude:1.5))
        XCTAssertFalse(geometry.contains(longitude:5,latitude:5))
    }

    func testSolarTermsFollowSolarPositionRatherThanMonthBoundaries() {
        let spring=ShanghaiTime.parseDay("2026-03-21")!.addingTimeInterval(12*3600)
        let summer=ShanghaiTime.parseDay("2026-06-23")!.addingTimeInterval(12*3600)
        let winter=ShanghaiTime.parseDay("2026-11-19")!.addingTimeInterval(12*3600)
        XCTAssertEqual(SolarTermPhase.name(at:spring),"春分")
        XCTAssertEqual(SolarTermPhase.name(at:summer),"夏至")
        XCTAssertEqual(SolarTermPhase.name(at:winter),"立冬")
        XCTAssertTrue((0..<360).contains(SolarTermPhase.longitude(at:winter)))
    }
}

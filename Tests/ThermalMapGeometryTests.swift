import XCTest
import Foundation
@testable import WeatherCore

final class ThermalMapGeometryTests: XCTestCase {
    func testBundledGeometryAcceptsUpdatedNineCityList() throws {
        // Exercise the actual bundle loader, which previously rejected nine
        // labels even though JSON decoding and structural checks succeeded.
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let url=root.appendingPathComponent("MapFixture.bundle")
        let contents=url.appendingPathComponent("Contents")
        let folder=contents.appendingPathComponent("Resources/ThermalMap")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let info:[String:Any] = ["CFBundleIdentifier":"test.thermal.map",
            "CFBundlePackageType":"BNDL","CFBundleVersion":"1"]
        try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0)
            .write(to:contents.appendingPathComponent("Info.plist"))
        let names=["suzhou","xuzhou","suqian","nanjing","hangzhou","ningbo","shanghai","lishui","qiandaohu"]
        let labels=names.map { ["name":$0,"latitude":30.0,"longitude":120.0] as [String:Any] }
        let ring=[[116.0,27.0],[123.0,27.0],[123.0,36.0],[116.0,36.0],[116.0,27.0]]
        let regions=["jiangsu","zhejiang","shanghai"].map {
            ["name":$0,"polygons":[[ring]]] as [String:Any]
        }
        func write(_ labels:[[String:Any]]) throws {
            let object:[String:Any] = ["schema":1,"bounds":[116,27,123,36],"regions":regions,"labels":labels]
            try JSONSerialization.data(withJSONObject:object).write(to:folder.appendingPathComponent("geometry.json"))
        }
        try write(labels)
        let bundle=try XCTUnwrap(Bundle(url:url))
        let geometry=try ThermalMapGeometry.bundled(in:bundle)
        XCTAssertEqual(geometry.labels.map(\.name),names)
        try write(labels+[labels[0]])
        XCTAssertThrowsError(try ThermalMapGeometry.bundled(in:bundle))
    }

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

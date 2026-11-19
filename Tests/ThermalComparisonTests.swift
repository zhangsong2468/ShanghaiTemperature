import XCTest
import Foundation
import CryptoKit
@testable import WeatherCore

final class ThermalComparisonTests: XCTestCase {
    func testShadeTemperatureUsesHumidityAndMetresPerSecond() throws {
        let calculate = ShadeApparentTemperature.calculate
        XCTAssertEqual(try calculate(30,50,2),31.57738163678242,accuracy:0.00001)
        XCTAssertEqual(try calculate(30,50,3),try calculate(30,50,2)-0.7,accuracy:0.00001)
        XCTAssertGreaterThan(try calculate(30,80,2),try calculate(30,50,2))
        XCTAssertThrowsError(try calculate(20,101,2))
        XCTAssertThrowsError(try calculate(20,50,-1))
        XCTAssertThrowsError(try calculate(.nan,50,2))
    }

    func testWindowIsSelectedByHistoricalCrossValidation() throws {
        let years = [0.0,20,-20].enumerated().map { i, anchor in
            HistoricalWindowYear(year:2015+i, anchor:[anchor], valuesByRadius:[0:[[anchor]],3:[[0,0,0]]])
        }
        let result = try ThermalComparisonEngine.selectWindow(years:years,radii:[0,3])
        XCTAssertEqual(result.radius,3)
        XCTAssertEqual(result.error,40.0/3,accuracy:0.00001)
    }

    private func fixture() throws -> (URL, HistoricalWeatherPoint) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var years:[[String:Any]]=[]
        for (year,temperature) in [(2022,10),(2023,20),(2024,30)] {
            let start=ShanghaiTime.calendar.date(from:DateComponents(year:year,month:1,day:1))!
            let end=ShanghaiTime.calendar.date(byAdding:.year,value:1,to:start)!
            let hours=Int(end.timeIntervalSince(start)/3600)
            let words:[UInt16]=[UInt16(temperature*100),5000,200]
            let record=words.flatMap { [UInt8($0 & 255),UInt8($0 >> 8)] }
            var data=Data();data.reserveCapacity(hours*6)
            for _ in 0..<hours { data.append(contentsOf:record) }
            try data.write(to:root.appendingPathComponent("\(year).bin"))
            years.append(["year":year,"file":"\(year).bin","hours":hours,"bytes":data.count,
                "sha256":SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()])
        }
        let point=HistoricalWeatherPoint(id:"p000",latitude:31,longitude:120)
        let index:[String:Any]=["schema":1,"model":"era5","timezone":"Asia/Shanghai","recordBytes":6,
            "scales":[100,100,100],"fields":["temperature_2m","relative_humidity_2m","wind_speed_10m"],
            "units":["°C","%","m/s"],"ordering":"point-major/hour-major",
            "points":[["id":"p000","latitude":31.0,"longitude":120.0]],"years":years]
        try JSONSerialization.data(withJSONObject:index).write(to:root.appendingPathComponent("index.json"))
        return (root,point)
    }

    func testMeanAcrossYearsAndNoChangeToCurrentApparentTemperature() async throws {
        let (root,point)=try fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        let archive=try HistoricalWeatherArchive(directory:root)
        let engine=ThermalComparisonEngine(archive:archive)
        let date=ShanghaiTime.parseDay("2026-11-19")!.addingTimeInterval(15*3600)
        let sample=HistoricalWeatherSample(point:point,date:date,temperature:25,relativeHumidity:50,windSpeed:2)
        let result=try await engine.compare(current:[sample],at:date,source:.local)
        XCTAssertEqual(result.historicalYears,[2022,2023,2024])
        XCTAssertEqual(result.source,.local)
        XCTAssertEqual(result.points[0].apparentTemperature,24.81118881589751,accuracy:0.00001)
        let expected=(6.622860653519286+18.44824231285815+31.57738163678242)/3
        XCTAssertEqual(result.points[0].historicalMean,expected,accuracy:0.00001)
        XCTAssertEqual(result.regionalAnomaly,result.points[0].apparentTemperature-expected,accuracy:0.00001)
        let past=try await archive.comparisonYears(around:ShanghaiTime.parseDay("2024-11-19")!,dayRadii:[0])
        XCTAssertEqual(past.map(\.year),[2022,2023])
    }

    func testLeapDayAndNewYearAreSafe() async throws {
        let (root,_)=try fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        let archive=try HistoricalWeatherArchive(directory:root)
        let leap=try await archive.comparisonYears(around:ShanghaiTime.parseDay("2028-02-29")!,dayRadii:[0,3])
        XCTAssertEqual(leap[0].valuesByRadius[0]![0].count,2)
        XCTAssertEqual(leap[2].valuesByRadius[0]![0].count,1)
        let january=try await archive.comparisonYears(around:ShanghaiTime.parseDay("2026-01-01")!,dayRadii:[0,3])
        XCTAssertEqual(january[0].valuesByRadius[3]![0].count,4)
    }

    func testRejectsMismatchedHourAndGrid() async throws {
        let (root,point)=try fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        let engine=ThermalComparisonEngine(archive:try HistoricalWeatherArchive(directory:root))
        let date=ShanghaiTime.parseDay("2026-11-19")!
        let wrong=HistoricalWeatherSample(point:point,date:date.addingTimeInterval(3600),temperature:20,relativeHumidity:50,windSpeed:2)
        do { _ = try await engine.compare(current:[wrong],at:date,source:.local);XCTFail("Mismatched hour") }
        catch ThermalComparisonError.mismatchedHour { }
        do { _ = try await engine.compare(current:[],at:date,source:.local);XCTFail("Missing grid") }
        catch ThermalComparisonError.mismatchedGrid { }
    }
}

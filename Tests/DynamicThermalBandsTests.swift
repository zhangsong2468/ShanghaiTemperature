import XCTest
import Foundation
@testable import WeatherCore

final class DynamicThermalBandsTests: XCTestCase {
    private func comparison(_ values: [Double], at date: Date, source: ThermalSource = .local) -> ThermalComparison {
        let points=values.indices.map { i in
            ThermalPointComparison(point:HistoricalWeatherPoint(id:"p\(i)",latitude:30+Double(i)*0.1,longitude:120),
                date:date,apparentTemperature:values[i],historicalMean:10,
                historicalYears:(0..<3).map { year in
                    ThermalReferenceYear(year:2015+year,apparentTemperatures:(0..<3).map { sample in
                        10+Double(year)+Double(i%2)*1.2+Double(sample)*0.2
                    })
                })
        }
        return ThermalComparison(source:source,date:date,points:points,historicalYears:[2015,2016,2017],
            selectedDayRadius:3,validationMeanAbsoluteError:1)
    }

    func testUniformAndSmallDifferencesProduceOneBand() throws {
        let date=ShanghaiTime.parseDay("2026-11-19")!
        let uniform=try DynamicThermalBands.build(from:comparison(Array(repeating:10,count:20),at:date))
        XCTAssertEqual(uniform.bands.count,1)
        XCTAssertEqual(uniform.bands[0].pointCount,20)
        let small=try DynamicThermalBands.build(from:comparison((0..<20).map {10+Double($0)*0.005},at:date))
        XCTAssertEqual(small.bands.count,1)
    }

    func testThreeMajorRegionsAndTemperatureShift() throws {
        let date=ShanghaiTime.parseDay("2026-11-19")!
        let values=Array(repeating:0.0,count:7)+Array(repeating:8.0,count:6)+Array(repeating:16.0,count:7)
        let a=try DynamicThermalBands.build(from:comparison(values,at:date))
        let b=try DynamicThermalBands.build(from:comparison(values.map {$0+1.37},at:date))
        XCTAssertEqual(a.baseCuts?.count,2)
        XCTAssertTrue(a.bands.allSatisfy { $0.upper-$0.lower <= 3.000000001 })
        XCTAssertEqual(a.points.map(\.apparentTemperature),values)
        XCTAssertEqual(a.bands.map(\.pointCount).reduce(0,+),20)
        for (old,new) in zip(a.cuts,b.cuts) {XCTAssertEqual(new-old,1.37,accuracy:0.000001)}
    }

    func testNearTieStabilityAndSourceChanges() throws {
        let date=ShanghaiTime.parseDay("2026-11-19")!
        let values=Array(repeating:0.0,count:10)+Array(repeating:12.0,count:10)
        let old=try DynamicThermalBands.build(from:comparison(values,at:date))
        let next=try DynamicThermalBands.build(from:comparison(values.map {$0+0.01},at:date.addingTimeInterval(3600)),previous:old)
        XCTAssertTrue(next.retainedPreviousCuts)
        let changed=try DynamicThermalBands.build(from:comparison(values.map {$0+30},at:date.addingTimeInterval(3600)),previous:old)
        XCTAssertFalse(changed.retainedPreviousCuts)
        let network=try DynamicThermalBands.build(from:comparison(values,at:date.addingTimeInterval(3600),source:.network),previous:old)
        XCTAssertFalse(network.retainedPreviousCuts)
    }

    func testThreeDegreeCapIncludesUnsampledIntervals() throws {
        let date=ShanghaiTime.parseDay("2026-11-19")!
        let values=Array(repeating:0.0,count:10)+Array(repeating:30.0,count:10)
        let result=try DynamicThermalBands.build(from:comparison(values,at:date))
        XCTAssertGreaterThan(result.bands.count,5)
        XCTAssertTrue(result.bands.allSatisfy { $0.upper-$0.lower <= 3.000000001 })
        XCTAssertEqual(result.bands.map(\.pointCount).reduce(0,+),20)
        XCTAssertEqual(result.bands.map {$0.upper-$0.lower}.reduce(0,+),30,accuracy:0.000001)
    }

    func testEmptyComparisonIsRejected() {
        let empty=ThermalComparison(source:.local,date:Date(),points:[],historicalYears:[],selectedDayRadius:0,validationMeanAbsoluteError:0)
        XCTAssertThrowsError(try DynamicThermalBands.build(from:empty))
    }
}
